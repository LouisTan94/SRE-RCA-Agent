# Tier 1 Platform — Setup Guide

## What Was Installed

### Windows Tools (via winget → copied to `C:\Users\kaisi\bin\`)
| Tool | Version | Purpose |
|------|---------|---------|
| minikube | v1.39.0 | Local Kubernetes cluster (Docker driver) |
| kubectl | v1.37.2 | Kubernetes CLI |
| Terraform | v1.16.6 (64-bit amd64) | Provisions minikube cluster via code |
| Helm | pre-existing | Kubernetes package manager (used by Terraform) |

> The old 32-bit Terraform (`C:\Program Files\Terraform`) is still present but shadowed by the 64-bit copy in `~/bin`.

### Git Bash Config Changes
| Setting | Value | Reason |
|---------|-------|--------|
| `core.fileMode` | `false` | Windows doesn't support Unix executable bits |
| `core.autocrlf` | `input` | Store LF in Git, avoid CRLF in scripts |

### Files Added to Repo
```
services/ui/                        ← Platform dashboard UI service
  main.py
  requirements.txt
  Dockerfile

tier1/gitops/ui/                    ← ArgoCD GitOps manifests for UI
  deployment.yaml
  service.yaml
  kustomization.yaml

tier1/gitops/apps/ui.yaml           ← ArgoCD Application definition
tier1/terraform/terraform.tfvars    ← Pins kubernetes_version = "v1.35.0"
GUIDE.md                            ← This file
```

### Kubernetes Cluster (`sre-tier1`)
Provisioned by Terraform on minikube with the Docker driver.

| Namespace | Workload | Purpose |
|-----------|----------|---------|
| `argocd` | ArgoCD | GitOps controller — watches Gitea, deploys services |
| `gitea` | Gitea | In-cluster Git server — source of truth for ArgoCD |
| `apps` | product-service | Demo microservice — products API |
| `apps` | order-service | Demo microservice — orders API |
| `apps` | ui | Platform dashboard (added in this session) |
| `ai-agent` | sre-agent | AI-powered RCA agent |
| `ai-agent` | mailpit | Local email inbox for RCA reports |

---

## How to Restart the Cluster

> Use this every time you come back. The cluster state (pods, secrets, Gitea, ArgoCD) is fully preserved.

Open **Git Bash** from the repo root:

```bash
cd /c/Users/kaisi/Documents/SRE-RCA-Agent

# 1. Resume the cluster (Docker Desktop must be running first)
minikube start -p sre-tier1

# 2. Open port-forwards in a terminal — keep it open
export PATH="$PATH:/c/Windows/System32"
bash ./tier1/scripts/forward.sh

# 3. (Optional) Open the UI dashboard in a second terminal
kubectl --context sre-tier1 -n apps port-forward svc/ui 9090:8000
```

**URLs after restart:**
| Service | URL |
|---------|-----|
| Platform UI | http://localhost:9090 |
| ArgoCD | http://localhost:8090 |
| Gitea | http://localhost:3000 |
| SRE Agent | http://localhost:8080/docs |
| Mailpit | http://localhost:8025 |

> **Tip:** Add `export PATH="$PATH:/c/Windows/System32"` to `~/.bashrc` so you don't need to run it every time.

---

## How to Start Everything (First Time / After Full Teardown)

### URLs
| Service | URL | Credentials |
|---------|-----|-------------|
| Platform UI | http://localhost:9090 | — |
| ArgoCD | http://localhost:8090 | `admin` / see below |
| Gitea | http://localhost:3000 | `sdlc` / see below |
| SRE Agent | http://localhost:8080/docs | — |
| Mailpit | http://localhost:8025 | — |

```bash
# Get ArgoCD password
kubectl --context sre-tier1 -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d

# Get Gitea password
terraform -chdir=./tier1/terraform output gitea_admin_password
```

> **Note:** The UI (port 9090) is a manual port-forward not in `forward.sh`.
> Run separately: `kubectl --context sre-tier1 -n apps port-forward svc/ui 9090:8000`

---

## Common Commands

```bash
# Run chaos + RCA
bash ./tier1/scripts/chaos.sh oom-product
bash ./tier1/scripts/chaos.sh crash-order
bash ./tier1/scripts/chaos.sh db-error
bash ./tier1/scripts/chaos.sh rca-only

# Check cluster resources
kubectl --context sre-tier1 top nodes
kubectl --context sre-tier1 top pods -A

# Check ArgoCD app status
bash ./tier1/scripts/sdlc.sh status

# Push changes to Gitea (triggers ArgoCD deploy)
. ./tier1/scripts/common.sh && git_gitea push gitea main

# Force ArgoCD refresh
kubectl --context sre-tier1 -n argocd annotate application root \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

## Teardown — Remove Everything

### 1. Destroy the Kubernetes cluster and all resources
```bash
cd /c/Users/kaisi/Documents/SRE-RCA-Agent
export PATH="$PATH:/c/Windows/System32"
bash ./tier1/scripts/down.sh
```

If `down.sh` fails, destroy manually:
```bash
terraform -chdir=./tier1/terraform destroy -auto-approve
minikube delete -p sre-tier1
```

### 2. Remove Terraform state
```bash
rm -f tier1/terraform/terraform.tfstate
rm -f tier1/terraform/terraform.tfstate.backup
rm -rf tier1/terraform/.terraform
```

### 3. Remove minikube profile data
```bash
rm -rf ~/.minikube/machines/sre-tier1
rm -rf ~/.minikube/profiles/sre-tier1
```

### 4. Remove kubectl context
```bash
kubectl config delete-context sre-tier1
kubectl config delete-cluster sre-tier1
```

### 5. Uninstall tools (PowerShell, Admin)
```powershell
winget uninstall Kubernetes.minikube
winget uninstall Kubernetes.kubectl
winget uninstall Hashicorp.Terraform
```

Remove the copies in `~/bin`:
```bash
rm ~/bin/minikube ~/bin/kubectl ~/bin/terraform ~/bin/python3
```

### 6. Revert Git Bash config (optional)
```bash
git config core.fileMode true
git config core.autocrlf true
```

### 7. Remove Helm repo (optional)
```bash
helm repo remove argo
```

---

## Architecture Overview

```
Git Bash (local)
│
├── tier1/scripts/bootstrap.sh   ← one-time setup
├── tier1/scripts/forward.sh     ← port-forwarding
├── tier1/scripts/chaos.sh       ← inject failures
└── tier1/scripts/sdlc.sh        ← agentic SDLC

Minikube cluster (sre-tier1)
│
├── argocd/           ← watches Gitea, deploys on push
├── gitea/            ← in-cluster Git remote
├── apps/
│   ├── product-service   ← products API
│   ├── order-service     ← orders API
│   └── ui                ← platform dashboard
└── ai-agent/
    ├── sre-agent     ← RCA engine (rule-based or Claude AI)
    └── mailpit       ← email inbox for RCA reports

GitOps flow:
  code change → git commit → git push to Gitea
  → ArgoCD detects → applies manifests → pod updated
```

---

## Known Issues & Fixes Applied

| Issue | Fix |
|-------|-----|
| `set: pipefail` error | Stripped CRLF from all `.sh` files (`core.autocrlf=input`) |
| minikube not in bash PATH | Copied binary to `~/bin` |
| 32-bit Terraform → 386 ISO 404 | Installed 64-bit Terraform via winget |
| `icacls.exe` not found | Added `/c/Windows/System32` to PATH before running bootstrap |
| `python3` stub (Microsoft Store) | Copied real Python from `AppData/Local/Programs` to `~/bin` |
| Gitea `--work-path` error | Removed explicit flags; gitea 1.27.3 uses correct defaults |
| Helm repo cache missing | Ran `helm repo add argo && helm repo update` |
