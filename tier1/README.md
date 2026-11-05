# Tier 1: GitOps + agentic SDLC on one minikube cluster

Everything runs on your laptop inside one minikube cluster on Docker (4 CPU / 6 GB).
Terraform builds it, ArgoCD deploys from an in-cluster Git server, and Claude agents
write, test and review changes before you approve them.

```
 you ──"sdlc.sh task"──▶ Claude lead agent ─┬─▶ coder     (edits code + tests)
                                            ├─▶ tester    (runs tests, read-only)
                                            └─▶ reviewer  (reviews diff, read-only)
                                                     │
                                                     ▼
                              Pull request in Gitea ◀── you review it in the browser
                                                     │
 you ──"sdlc.sh ship N"──▶ merge ─▶ ci.sh: test ─▶ build image ─▶ bump tag in Git
                                                                       │
                                     ArgoCD (watches Gitea) ◀──────────┘
                                                     │ deploys
                                                     ▼
                              verify.sh: synced? healthy? stable for 45s?
                                 │ no
                                 ▼
                    SRE agent writes an RCA (emailed to Mailpit) + git revert ─▶ ArgoCD rolls back
```

## What's inside the cluster

| Namespace | What | Approx. RAM |
|---|---|---|
| kube-system | Kubernetes itself + metrics-server | 1.2 GB |
| argocd | ArgoCD (no Dex, notifications or ApplicationSet controller) | 1.2–1.5 GB |
| gitea | Gitea: the Git server ArgoCD pulls from and agents open PRs in | 0.3 GB |
| apps | product-service, order-service (demo apps with chaos endpoints) | 0.2 GB |
| ai-agent | SRE agent (read-only RBAC) + Mailpit (catches RCA emails) | 0.3 GB |

That's about 3.5 GB used of the 6 GB node, leaving headroom for deploys and the OOM test.

**On the host:**
- Terraform
- the CI script (builds images straight into minikube; no registry needed)
- the Claude agents, about 0.5 GB while running. The model itself runs on Anthropic's servers.

## Prerequisites

- **Docker:** Docker Desktop with at least 8 GB of memory allocated (Settings → Resources), or Docker Engine on Linux.
- **minikube:** https://minikube.sigs.k8s.io/docs/start/
- **kubectl, Terraform ≥ 1.6, git, Python ≥ 3.10, curl**
- **A bash shell:** macOS, Linux, or WSL2 on Windows.
- **A Claude API key** from https://console.anthropic.com. It's needed for the coding agents. Without it, the SRE agent falls back to rule-based mode.
- **A 16 GB laptop works.** Close heavy apps while it's running.

## Setup (once, about 10 minutes)

From the repository root, on the `main` branch:

```bash
cp tier1/.env.example tier1/.env     # set ANTHROPIC_API_KEY
./tier1/scripts/bootstrap.sh         # Terraform + push to Gitea + build images + ArgoCD sync
./tier1/scripts/forward.sh           # second terminal: opens the UIs, prints logins
```

| UI | URL | Login |
|---|---|---|
| ArgoCD | http://localhost:8090 | `admin` / printed by forward.sh |
| Gitea | http://localhost:3000 | `sdlc` / printed by forward.sh |
| SRE agent | http://localhost:8080/docs | `x-api-key` header (in the `agent-secrets` secret) |
| Mailpit | http://localhost:8025 | none |

## The loop

### 1. Ask for a change

```bash
./tier1/scripts/sdlc.sh task "Add a GET /products/{id}/stock endpoint to product-service that returns only the stock count"
```

You'll see the lead agent plan the change and hand off to `coder`, `tester` and `reviewer`. It loops up to twice to fix problems. The script then:
- commits the work on an `agent/...` branch
- pushes it to Gitea
- opens a PR with the test and review results

A PR the agents couldn't get to green is titled `WIP:`, and `ship` refuses to merge it.

**Guardrails on the agents:**
- They can't commit, push, switch branches, or run `kubectl`, `minikube`, `terraform`, `docker` or `curl`.
- They can't touch `tier1/terraform` or image tags.
- Each run stops at `SDLC_BUDGET_USD` (default $3).
- Subagents can't spawn their own subagents.

### 2. Review the PR in Gitea

Open http://localhost:3000/sdlc/platform/pulls. Read the diff and the agents' notes, and comment or edit if you like. Nothing is deployed yet.

### 3. Ship it

```bash
./tier1/scripts/sdlc.sh ship 1
```

This works through these steps:
1. Merges the PR.
2. Works out which services changed.
3. Runs `ci.sh`: tests, then builds an image tagged with the commit, then commits the new tag to `tier1/gitops/<service>`, then pushes.
4. ArgoCD deploys the new tag.
5. `verify.sh` waits for **Synced + Healthy**, watches for restarts for 45 seconds, and calls `/healthz`.

If verification fails, the SRE agent investigates and emails an RCA to Mailpit, including ArgoCD's deploy history. The deploy commit is then reverted, so ArgoCD rolls back automatically.

### Other commands

| Command | What it does |
|---|---|
| `sdlc.sh prs` | List open PRs |
| `sdlc.sh status` | ArgoCD application status |
| `ci.sh <service>` / `ci.sh --all` | Build and deploy without an agent (e.g. after editing code yourself on main) |
| `verify.sh <service> [--no-rollback]` | Run the deploy gate on its own |
| `test.sh <service>` / `test.sh --all` | Unit tests only |
| `chaos.sh oom-product` (also `crash-order`, `crash-product`, `db-error`) | Break a running service and get an RCA |
| `minikube stop -p sre-tier1` | Pause everything (keeps the state) |
| `down.sh` | Destroy the cluster (your local git history is kept) |

## Try the safety net

To see the automatic RCA and rollback, ship a change that passes the unit tests but crashes inside Kubernetes:

```bash
cat >> services/order-service/main.py <<'EOF'

# Deliberate bug: only crashes when running in a cluster, so unit tests still pass.
if os.getenv("KUBERNETES_SERVICE_HOST"):
    raise RuntimeError("missing PAYMENT_GATEWAY_URL")
EOF
git commit -am "feat(order-service): wire payment gateway"
./tier1/scripts/ci.sh order-service
```

Expected result:
- The tests pass and the image deploys.
- `verify.sh` sees CrashLoopBackOff.
- The SRE agent's RCA names the `RuntimeError`.
- The tag bump is reverted and order-service is restored.

The broken code commit itself is still on main. Undo it with `git revert HEAD~1`, or better, ask the agents to fix it:

```bash
./tier1/scripts/sdlc.sh task "Fix order-service crashing on startup in Kubernetes (see the latest RCA in Mailpit)"
```

## How the pieces fit

| Path | Purpose |
|---|---|
| `tier1/terraform/` | minikube cluster, ArgoCD (Helm), Gitea, ArgoCD repo credentials, root app-of-apps |
| `tier1/gitops/apps/` | One ArgoCD Application per service (created by the root app) |
| `tier1/gitops/<service>/` | Kustomize manifests. `newTag:` is owned by `ci.sh` |
| `tier1/scripts/` | bootstrap, ci, verify, sdlc, chaos, forward, down, plus the Gitea API helper |
| `tier1/agents/sdlc_agent.py` | Claude Agent SDK orchestrator with coder / tester / reviewer subagents |
| `services/*/tests/` | Unit tests run by CI and by the tester subagent |

The `agent-secrets` secret (Claude key, API key) is created by `bootstrap.sh` and is never committed to Git.
The Gitea password is generated by Terraform. Scripts pass it per command, so it isn't stored in `.git/config`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `terraform apply` fails on the minikube provider | Run `minikube start --driver=docker --download-only` once, then re-run bootstrap. |
| App stuck `Unknown` / repo errors in ArgoCD | Gitea wasn't ready when ArgoCD first looked. Re-run `bootstrap.sh`; it's idempotent. |
| Pod in `ErrImageNeverPull` | The image for that tag isn't in minikube. Run `ci.sh <service>`, or re-run bootstrap. |
| `Local main has diverged` | You committed to main while Gitea also moved. Run `git pull --rebase gitea main`, then push. |
| Agent PR titled `WIP:` | Read the PR's notes. Re-run `sdlc.sh task` with a sharper request, or fix it by hand. |
| Port in use | Change the ports in `tier1/.env`. |
| Low on memory | Run `kubectl --context sre-tier1 top pods -A` and `docker stats`. Don't run the `local/` setup at the same time. |

## Relationship to `local/`

`local/` is the quick, kubectl-only way to run the demo, with no Terraform, ArgoCD or Git server. Tier 1 replaces it with the full GitOps and agent workflow. Use one or the other, not both at once.
