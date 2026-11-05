#!/usr/bin/env python3
"""Tiny Gitea API client (standard library only) used by the Tier 1 scripts and the SDLC agent.

Reads GITEA_URL, GITEA_USER, GITEA_PASS and GITEA_REPO ("owner/name") from the environment.

  gitea_api.py ensure-repo
  gitea_api.py open-pr --head BRANCH --title TITLE --body-file FILE   -> prints PR number
  gitea_api.py list-prs
  gitea_api.py pr-json NUMBER
  gitea_api.py merge-pr NUMBER
"""
import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request


def _env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"gitea_api: {name} is not set")
    return value


def call(method, path, payload=None, ok=(200, 201, 204)):
    url = _env("GITEA_URL").rstrip("/") + "/api/v1" + path
    token = base64.b64encode(f'{_env("GITEA_USER")}:{_env("GITEA_PASS")}'.encode()).decode()
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Basic {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
            return resp.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        if e.code in ok:
            return e.code, None
        raise SystemExit(f"gitea_api: {method} {path} -> HTTP {e.code}: {body[:300]}")


def repo():
    return _env("GITEA_REPO")


def ensure_repo(_args):
    owner, name = repo().split("/", 1)
    status, _ = call("GET", f"/repos/{owner}/{name}", ok=(200, 404))
    if status == 200:
        print(f"repo {owner}/{name} already exists")
        return
    call("POST", "/user/repos", {"name": name, "private": True, "default_branch": "main",
                                 "description": "Tier 1 platform repo watched by ArgoCD"})
    print(f"created repo {owner}/{name}")


def open_pr(args):
    body = open(args.body_file, encoding="utf-8").read() if args.body_file else ""
    _, pr = call("POST", f"/repos/{repo()}/pulls",
                 {"head": args.head, "base": args.base, "title": args.title, "body": body})
    print(pr["number"])


def list_prs(_args):
    _, prs = call("GET", f"/repos/{repo()}/pulls?state=open&limit=50")
    if not prs:
        print("No open pull requests.")
    for pr in prs or []:
        print(f'#{pr["number"]:<4} {pr["title"]}   ({pr["head"]["ref"]})')


def pr_json(args):
    _, pr = call("GET", f"/repos/{repo()}/pulls/{args.number}")
    print(json.dumps({k: pr.get(k) for k in ("number", "title", "state", "merged", "mergeable", "html_url")}
                     | {"head": pr["head"]["ref"]}))


def merge_pr(args):
    _, pr = call("GET", f"/repos/{repo()}/pulls/{args.number}")
    if pr.get("merged"):
        sys.exit(f"PR #{args.number} is already merged.")
    if pr.get("state") != "open":
        sys.exit(f"PR #{args.number} is {pr.get('state')}.")
    if pr["title"].lower().startswith(("wip:", "[wip]")):
        sys.exit(f"PR #{args.number} is marked WIP (tests failed or review asked for changes). "
                 "Fix it, retitle it in Gitea, then ship again.")
    if pr.get("mergeable") is False:
        sys.exit(f"PR #{args.number} has conflicts with main. Resolve them first.")
    call("POST", f"/repos/{repo()}/pulls/{args.number}/merge",
         {"Do": "merge", "delete_branch_after_merge": True})
    print(f"merged PR #{args.number}: {pr['title']}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ensure-repo").set_defaults(fn=ensure_repo)
    o = sub.add_parser("open-pr")
    o.add_argument("--head", required=True)
    o.add_argument("--base", default="main")
    o.add_argument("--title", required=True)
    o.add_argument("--body-file")
    o.set_defaults(fn=open_pr)
    sub.add_parser("list-prs").set_defaults(fn=list_prs)
    for name, fn in (("pr-json", pr_json), ("merge-pr", merge_pr)):
        s = sub.add_parser(name)
        s.add_argument("number", type=int)
        s.set_defaults(fn=fn)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
