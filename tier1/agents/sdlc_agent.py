#!/usr/bin/env python3
"""Agentic SDLC: turn a change request into a reviewed pull request in Gitea.

An orchestrator agent plans the work and delegates to three subagents:
  coder     - edits code and tests
  tester    - runs the test suites and reports PASS/FAIL (read-only)
  reviewer  - reviews the diff for correctness, security and test coverage (read-only)

This script owns the git side: it creates the branch, commits, pushes and opens the PR.
The agents can't push, commit, switch branches or touch the cluster. Deploying only
happens when a human runs `sdlc.sh ship <PR>`.

Run it through tier1/scripts/sdlc.sh, which sets up the venv and Gitea credentials.
"""
import argparse
import asyncio
import base64
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from claude_agent_sdk import (
    AgentDefinition,
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
    query,
)

TIER1 = Path(__file__).resolve().parents[1]
REPO = TIER1.parent
GITEA_API = TIER1 / "scripts" / "gitea_api.py"
SERVICES = ["product-service", "order-service", "sre-agent"]

# Commands no agent may run. Git history, deploys and the cluster belong to the scripts and the human.
DENY_BASH = [
    "Bash(git push *)", "Bash(git commit *)", "Bash(git checkout *)", "Bash(git switch *)",
    "Bash(git reset *)", "Bash(git rebase *)", "Bash(git merge *)", "Bash(git branch *)",
    "Bash(git stash *)", "Bash(git remote *)",
    "Bash(kubectl *)", "Bash(minikube *)", "Bash(terraform *)", "Bash(helm *)", "Bash(docker *)",
    "Bash(curl *)", "Bash(wget *)", "Bash(sudo *)", "Bash(rm -rf *)",
    "Bash(*ci.sh*)", "Bash(*sdlc.sh*)", "Bash(*bootstrap.sh*)", "Bash(*down.sh*)", "Bash(*verify.sh*)",
]

REPO_CONTEXT = f"""
Repository layout (you are at the repo root):
- services/product-service, services/order-service: FastAPI demo microservices (main.py, tests/).
- services/sre-agent: the AI SRE agent (app.py, agent.py, tools.py, mailer.py, report.py, tests/).
- tier1/gitops/<service>/: Kubernetes manifests that ArgoCD deploys. Never change `newTag:` lines;
  the CI script owns image tags.
- tier1/terraform/: cluster infrastructure. Out of scope; never edit it.
Run a service's tests with: tier1/scripts/test.sh <service>   (services: {", ".join(SERVICES)})
"""

CODER = AgentDefinition(
    description="Implements code changes and their tests. Use for any edit to the repository.",
    prompt=REPO_CONTEXT + """
You are the coder. Implement exactly the change you are given, as a small, focused diff.
- Match the existing style. Don't refactor unrelated code or add dependencies unless required.
- Add or update tests in services/<service>/tests for every behaviour you change.
- Run tier1/scripts/test.sh for each service you touched and fix failures before reporting.
- Never commit, push or switch branches. Never touch tier1/terraform or `newTag:` lines.
Report: the files you changed, what you did, and the final test output (last few lines).""",
    tools=["Read", "Grep", "Glob", "Edit", "Write", "Bash"],
    disallowedTools=DENY_BASH,
)

TESTER = AgentDefinition(
    description="Runs the test suites and reports PASS or FAIL with evidence. Read-only.",
    prompt=REPO_CONTEXT + """
You are the tester. Do not edit files.
1. Find which services changed: `git status --porcelain` and `git diff --stat`.
2. Run tier1/scripts/test.sh for each changed service (all three if unsure).
3. Check whether the new behaviour is actually covered by a test; name any gap.
Finish with exactly one line: `TESTS: PASS` or `TESTS: FAIL`, preceded by the evidence
(failing test names and error lines, quoted).""",
    tools=["Read", "Grep", "Glob", "Bash"],
    disallowedTools=DENY_BASH + ["Edit", "Write"],
)

REVIEWER = AgentDefinition(
    description="Reviews the working-tree diff like a senior engineer. Read-only.",
    prompt=REPO_CONTEXT + """
You are the code reviewer. Do not edit files. Read the change with `git diff` and
`git status --porcelain` (read new untracked files in full). Check:
- Correctness against the request, edge cases and error handling.
- Security: secrets in code, weakened auth (the x-api-key check), widened RBAC,
  removed guardrails such as the untrusted-data wrapping or secret redaction in sre-agent.
- Kubernetes manifests: resource limits kept, no privilege escalation, `newTag:` untouched.
- Tests that really exercise the change.
List concrete issues as `file:line - problem - fix`. Finish with exactly one line:
`REVIEW: APPROVE` or `REVIEW: CHANGES_REQUESTED`.""",
    tools=["Read", "Grep", "Glob", "Bash"],
    disallowedTools=DENY_BASH + ["Edit", "Write"],
)

ORCHESTRATOR_PROMPT = REPO_CONTEXT + """
You are the engineering lead running a small team of subagents: coder, tester, reviewer.
You never edit files yourself; you plan and delegate through the Agent tool.

Workflow:
1. Read just enough of the code to write a precise plan (files, functions, tests).
2. Send the plan to the coder. Give it everything it needs: it can't see this conversation.
3. Ask the tester to verify, then the reviewer to review.
4. If tests fail or the reviewer requests changes, send the specific problems back to the
   coder, then re-test and re-review. At most 2 fix rounds.
5. Stop when tests pass and the reviewer approves, or the rounds run out.

Your final message must end with exactly these lines, filled in:
SUMMARY: <2-4 sentences: what changed and why>
COMMIT: <conventional commit message, e.g. feat(product-service): add stock endpoint>
TESTS: PASS|FAIL
REVIEW: APPROVE|CHANGES_REQUESTED
NOTES: <open issues for the human reviewer, or "none">
"""


def git(*args, check=True, auth=False):
    cmd = ["git", "-C", str(REPO)]
    if auth:
        token = base64.b64encode(f'{os.environ["GITEA_USER"]}:{os.environ["GITEA_PASS"]}'.encode()).decode()
        cmd += ["-c", f"http.extraHeader=Authorization: Basic {token}"]
    out = subprocess.run(cmd + list(args), capture_output=True, text=True)
    if check and out.returncode != 0:
        sys.exit(f"git {' '.join(args)} failed:\n{out.stderr.strip()}")
    return out.stdout.strip()


def field(text, name, default=""):
    matches = re.findall(rf"^\s*\**{name}\**:\s*(.+)$", text or "", flags=re.MULTILINE)
    return matches[-1].strip() if matches else default


def slugify(text, limit=40):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:limit].strip("-") or "change"


async def run_team(task, budget, model):
    options = ClaudeAgentOptions(
        system_prompt=ORCHESTRATOR_PROMPT,
        agents={"coder": CODER, "tester": TESTER, "reviewer": REVIEWER},
        # Auto-approve these so the run is unattended; the deny list above still applies.
        allowed_tools=["Read", "Grep", "Glob", "Edit", "Write", "Bash", "Agent"],
        disallowed_tools=DENY_BASH,
        permission_mode="acceptEdits",
        cwd=str(REPO),
        setting_sources=[],  # ignore personal ~/.claude settings for repeatable runs
        max_turns=80,
        max_budget_usd=budget,
        model=model,
        env={
            "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1",  # subagents can't spawn their own
            "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "2",
        },
    )

    final_text, cost, outcome = "", None, "unknown"
    async for msg in query(prompt=f"Change request:\n{task}", options=options):
        if isinstance(msg, AssistantMessage) and msg.parent_tool_use_id is None:
            for block in msg.content:
                if isinstance(block, ToolUseBlock) and block.name in ("Agent", "Task"):
                    who = block.input.get("subagent_type", "subagent")
                    desc = block.input.get("description", "")
                    print(f"\n  -> {who}: {desc}", flush=True)
                elif isinstance(block, TextBlock) and block.text.strip():
                    print(f"\n[lead] {block.text.strip()[:600]}", flush=True)
        elif isinstance(msg, ResultMessage):
            outcome, cost = msg.subtype, msg.total_cost_usd
            final_text = msg.result or final_text
    return final_text, cost, outcome


def main():
    ap = argparse.ArgumentParser(description="Turn a change request into a reviewed Gitea PR.")
    ap.add_argument("task", help="What to change, in plain language")
    ap.add_argument("--budget", type=float, default=float(os.environ.get("SDLC_BUDGET_USD", "3")),
                    help="Stop when the estimated API cost reaches this (USD). Default 3.")
    ap.add_argument("--model", default=os.environ.get("SDLC_MODEL") or None,
                    help="Model for the lead and subagents (default: SDK default).")
    args = ap.parse_args()

    if git("branch", "--show-current") != "main" or git("status", "--porcelain"):
        sys.exit("Start from a clean main branch (sdlc.sh task does this for you).")

    branch = f"agent/{slugify(args.task)}-{time.strftime('%m%d-%H%M%S')}"
    git("checkout", "-q", "-b", branch)
    print(f"Working on branch {branch} (budget ${args.budget:.2f})")

    try:
        final, cost, outcome = asyncio.run(run_team(args.task, args.budget, args.model))
    except BaseException:
        print("\nAgent run interrupted; leaving the branch as-is for inspection.")
        raise

    cost_txt = f"${cost:.2f}" if cost is not None else "unknown"
    print(f"\n=== Agent run finished: {outcome}, estimated cost {cost_txt} ===")

    if not git("status", "--porcelain"):
        git("checkout", "-q", "main")
        git("branch", "-q", "-D", branch)
        sys.exit("The agents made no changes, so there is nothing to review.\n" + (final or ""))

    summary = field(final, "SUMMARY", "(no summary)")
    commit = field(final, "COMMIT", f"chore: {args.task[:60]}")
    tests = field(final, "TESTS", "UNKNOWN").upper()
    review = field(final, "REVIEW", "UNKNOWN").upper()
    notes = field(final, "NOTES", "none")
    ready = tests.startswith("PASS") and review.startswith("APPROVE") and outcome == "success"

    git("add", "-A")
    git("commit", "-q", "-m", f"{commit}\n\n{summary}\n\nRequested: {args.task}\nGenerated-by: sdlc-agent")
    git("push", "-q", "-u", "gitea", branch, auth=True)

    title = commit if ready else f"WIP: {commit}"
    body = f"""## Request
{args.task}

## Summary
{summary}

## Agent checks
| Check | Result |
|---|---|
| Tests (tester subagent) | {tests} |
| Review (reviewer subagent) | {review} |
| Run outcome | {outcome} |
| Estimated cost | {cost_txt} |

## Notes for the human reviewer
{notes}

---
Ship it after your review: `./tier1/scripts/sdlc.sh ship <this PR number>`
"""
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(body)
    pr = subprocess.run([sys.executable, str(GITEA_API), "open-pr", "--head", branch,
                         "--title", title, "--body-file", f.name],
                        capture_output=True, text=True)
    os.unlink(f.name)
    git("checkout", "-q", "main")

    if pr.returncode != 0:
        sys.exit(f"Branch pushed, but opening the PR failed:\n{pr.stderr or pr.stdout}")
    number = pr.stdout.strip()
    url = f'{os.environ["GITEA_URL"]}/{os.environ["GITEA_REPO"]}/pulls/{number}'
    print(f"""
Pull request #{number}: {title}
  {url}
  tests: {tests}   review: {review}

{"Review it, then ship:  ./tier1/scripts/sdlc.sh ship " + number if ready else
 "Marked WIP - the agents couldn't get it to green. Check the PR notes, fix or re-run."}""")


if __name__ == "__main__":
    main()
