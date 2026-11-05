# Run SRE-RCA-Agent locally on minikube (Docker driver)

This folder runs the whole demo on your own machine: the two demo microservices,
the AI SRE agent, and a local email inbox. No AWS, Terraform, ECR or ArgoCD.

```
your laptop
└── Docker
    └── minikube (profile "sre-lab")
        ├── apps namespace
        │   ├── product-service   (chaos: /chaos/oom, /chaos/crash)
        │   └── order-service     (chaos: /chaos/crash, /chaos/db-error)
        └── ai-agent namespace
            ├── sre-agent         read-only RBAC, writes RCA reports, sends email
            └── mailpit           catches the RCA emails (replaces AWS SES)
```

## What changed from the cloud version

| Cloud version | Local version |
|---|---|
| EC2 + k3s via Terraform | minikube with the Docker driver |
| Images in ECR | Built straight into minikube (`minikube image build`), no registry |
| ArgoCD deploys | `kubectl apply` from `local/k8s/` (the agent's ArgoCD tools just report "not installed") |
| AWS SES email | Mailpit, a local inbox at http://localhost:8025 |
| NodePorts 30080–30082 | `kubectl port-forward` (works the same on macOS, Windows and Linux) |

Small code fixes in `services/sre-agent/`:
- **Model:** the default model is now `claude-sonnet-5-5`. The old default was a retired model, which made the agent silently fall back to rules.
- **Rule-based fallback:** its reports are now labelled `[Rule-based]`. They no longer claim "high" confidence.
- **Email:** `EMAIL_PROVIDER=smtp` stops the agent trying AWS SES first whenever it runs inside Kubernetes.
- **Timezone:** report times follow `REPORT_TIMEZONE`, set to `Asia/Singapore` here. They were hard-coded to IST.
- **API key:** `AGENT_API_KEY` is always set. `up.sh` generates one, so the API is never left open.

## Prerequisites

- **Docker:** Docker Desktop (macOS/Windows) or Docker Engine (Linux), running, with at least 4 GB of memory available to it.
- **minikube:** https://minikube.sigs.k8s.io/docs/start/
- **kubectl:** https://kubernetes.io/docs/tasks/tools/
- **A bash shell:** macOS Terminal, Linux, or WSL2 on Windows.
- **Optional: a Claude API key** from https://console.anthropic.com. Without one, the agent runs in rule-based mode.

## Quick start

All commands run from the repository root.

```bash
# 1. Settings (optional, but add your API key for real LLM analysis)
cp local/.env.example local/.env
#    then edit local/.env and set ANTHROPIC_API_KEY=sk-ant-...

# 2. Start minikube, build images, deploy everything (about 3-5 minutes the first time)
./local/scripts/up.sh

# 3. In a second terminal, expose the UIs on localhost (leave it running)
./local/scripts/forward.sh

# 4. Break something and get an RCA
./local/scripts/chaos.sh oom-product
```

Then open:
- **Latest RCA report:** http://localhost:8080/rca/latest
- **Email inbox:** http://localhost:8025. The RCA email has the HTML report attached.
- **Agent API (Swagger):** http://localhost:8080/docs. Send the `x-api-key` header.

## Failure scenarios

| Command | What happens | What the RCA should find |
|---|---|---|
| `chaos.sh oom-product` | product-service allocates memory past its 128Mi limit | OOMKilled, exit code 137 |
| `chaos.sh crash-order` | order-service exits with code 1 | Crash with a fatal log line; pod restarted |
| `chaos.sh crash-product` | product-service exits with code 1 | Same, for product-service |
| `chaos.sh db-error` | order-service logs a fake DB pool exhaustion | DB connection pool exhausted |
| `chaos.sh rca-only` | Nothing is broken; just runs an RCA | Whatever is currently wrong, or "healthy" |

Add a recipient as the second argument, e.g. `chaos.sh crash-order me@example.com`.
Every address ends up in Mailpit; nothing leaves your machine.

Restarts count as "issues" until the pod is recreated. To start from a clean slate, run:

```bash
kubectl --context sre-lab -n apps rollout restart deploy/product-service deploy/order-service
```

## Calling the API yourself

```bash
KEY=$(kubectl --context sre-lab -n ai-agent get secret agent-secrets \
      -o jsonpath='{.data.agent_api_key}' | base64 --decode)

# Chat with the agent
curl -s localhost:8080/chat -H "x-api-key: $KEY" -H 'Content-Type: application/json' \
     -d '{"message":"Which pods in apps have restarted, and why?"}'

# Scan + RCA + email in one call
curl -s -X POST "localhost:8080/rca/auto-scan?email_to=oncall@local.test" -H "x-api-key: $KEY"
```

## Day-to-day

| Task | Command |
|---|---|
| Rebuild and redeploy after editing code | `./local/scripts/up.sh` (re-runnable) |
| Agent logs | `kubectl --context sre-lab -n ai-agent logs deploy/sre-agent -f` |
| Pod status | `kubectl --context sre-lab get pods -A` |
| Pause the cluster (keeps everything) | `minikube stop -p sre-lab` |
| Remove the apps, keep the cluster | `./local/scripts/down.sh` |
| Delete everything | `./local/scripts/down.sh --all` |

## Troubleshooting

- **The report is titled `[Rule-based] ...`.** No working Claude API key reached the agent. Set `ANTHROPIC_API_KEY` in `local/.env` and re-run `up.sh`. Then check the logs for an error from the Anthropic client.
- **`minikube start` fails on memory.** Give Docker Desktop more memory, or set `MINIKUBE_MEMORY=3072` in `local/.env`.
- **A port is already in use.** Change `AGENT_PORT` or `MAILPIT_PORT` in `local/.env`.
- **A pod is stuck in `ErrImageNeverPull`.** The image build didn't finish. Re-run `up.sh`, or check `minikube -p sre-lab image ls | grep local/`.
- **On Windows:** run the scripts from WSL2, with Docker Desktop's WSL integration turned on.
