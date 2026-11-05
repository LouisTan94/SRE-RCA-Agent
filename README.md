# RCA Platform – Autonomous AI SRE & Microservices Platform

An enterprise-grade, end-to-end Kubernetes platform featuring:
- 🏗️ **Microservices Architecture:** Distributed `order-service` and `product-service` built with FastAPI.
- ⚙️ **Infrastructure as Code (Terraform):** Automated AWS provisioning (VPC, Security Groups, IAM with OIDC, ECR repositories, and EC2 with single-node **k3s cluster** installed via user-data).
- 🔄 **GitOps & CI/CD:** Continuous Integration via **GitHub Actions** (OIDC, automated ECR pushes, and GitOps manifest tag updates) and Continuous Deployment via **ArgoCD** (App-of-Apps pattern).
- 🧠 **Autonomous AI SRE Agent:** Continuous Kubernetes cluster observer that gathers logs, container exit codes, and Warning events to diagnose incidents, perform Root Cause Analysis (RCA) with Claude or automated heuristics, and dispatch **email notifications with an attached interactive HTML RCA report**.
- 💥 **Integrated Chaos Testing:** Built-in chaos endpoints to simulate real-world failure scenarios (`OOMKilled`, `CrashLoopBackOff`, and Database pool exhaustion) for instant demonstration.

> **Run it locally:** see [`local/README.md`](local/README.md) to run everything on minikube with Docker (no AWS needed).

---

## 🏛️ Architecture Overview

```text
                                  +-------------------------------------------------------------+
                                  |                     AWS Cloud (ap-south-1)                  |
                                  |                                                             |
+-------------------+             |   +-----------------------+     +-----------------------+   |
|   GitHub Actions  |--- OIDC --->|   |  ECR Container Regist |     |  Amazon SES / SMTP    |   |
|   CI Pipeline     |-- Push ---->|   |  - ai-sre-agent       |     |  Email Notifications  |   |
+---------+---------+             |   |  - order-service      |     |  with HTML Attachment |   |
          |                       |   |  - product-service    |     +-----------^-----------+   |
          | Update Image Tags     |   +-----------+-----------+                 |               |
          v                       |               | Pull Images                 | Sends Alert   |
+-------------------+             |               v                             | & Report      |
|  GitOps (ArgoCD)  |============>|   +-----------------------------------------+-----------+   |
|  Reconciliation   |             |   |               EC2 k3s Cluster Node                  |   |
+-------------------+             |   |                                                     |   |
                                  |   |   [argocd] Namespace                                |   |
                                  |   |     • argocd-server (NodePort :30443)               |   |
                                  |   |                                                     |   |
                                  |   |   [apps] Namespace (Microservices)                  |   |
                                  |   |     • order-service   (NodePort :30081)             |   |
                                  |   |     • product-service (NodePort :30082)             |   |
                                  |   |                                                     |   |
                                  |   |   [ai-agent] Namespace                              |   |
                                  |   |     • sre-agent       (NodePort :30080)             |   |
                                  |   |       - Reads Pod Statuses, Logs & Events           |   |
                                  |   |       - Diagnoses Failures & Generates HTML RCA     |   |
                                  |   +-----------------------------------------------------+   |
                                  +-------------------------------------------------------------+
```

---

## 📂 Repository Layout

```
RCA_Platform/
├── .github/
│   └── workflows/
│       └── ci-cd.yml                     # Multi-service build, ECR push & GitOps manifest updater
│
├── gitops/                               # ArgoCD GitOps Manifests
│   ├── apps/
│   │   ├── namespaces.yaml               # 'apps' and 'ai-agent' namespaces
│   │   ├── order-service/                # Deployment & Service (NodePort 30081)
│   │   ├── product-service/              # Deployment & Service (NodePort 30082)
│   │   └── sre-agent/                    # Deployment, Service (30080) & RBAC ClusterRole
│   └── argocd/
│       ├── root-application.yaml         # ArgoCD App-of-Apps master manifest
│       ├── application-order-service.yaml
│       ├── application-product-service.yaml
│       └── application-sre-agent.yaml
│
├── services/
│   ├── order-service/                    # Order placement & catalog consumer (FastAPI)
│   │   ├── main.py                       # HTTP API + Chaos endpoints (/chaos/crash, /chaos/db-error)
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   │
│   ├── product-service/                  # Inventory management (FastAPI)
│   │   ├── main.py                       # HTTP API + OOM injection (/chaos/oom, /chaos/latency)
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   │
│   └── sre-agent/                        # Autonomous AI SRE & RCA Agent (FastAPI + CLI)
│       ├── app.py                        # REST endpoints (/rca, /rca/auto-scan, /rca/latest, /chat)
│       ├── agent.py                      # Claude LLM tool-use loop + intelligent heuristic fallback
│       ├── tools.py                      # Kubernetes cluster scanner, log tailer, event fetcher
│       ├── report.py                     # HTML RCA renderer & email body generator
│       ├── mailer.py                     # AWS SES & standard SMTP multipart mailer with HTML attachment
│       ├── cli.py                        # Terminal CLI runner (`python cli.py rca`)
│       ├── Dockerfile
│       ├── requirements.txt
│       ├── templates/
│       │   └── rca.html.j2               # Modern interactive HTML RCA template
│       └── runbooks/                     # Knowledge base (crashloop, oomkilled, imagepull)
│
├── infra-terraform/                      # AWS Infrastructure as Code
│   ├── bootstrap/                        # S3 Remote State bucket + DynamoDB Lock Table
│   ├── modules/
│   │   ├── vpc/                          # Custom VPC, Public/Private Subnets, IGW, NAT Gateway
│   │   ├── security-groups/              # k3s Server SG (SSH 22, API 6443, NodePort 30000-32767)
│   │   ├── iam/                          # EC2 Node Role & GitHub Actions OIDC Role
│   │   ├── ecr/                          # ECR repositories (ai-sre-agent, order-service, product-service)
│   │   └── k3s-cluster/                  # EC2 Instance with k3s cluster installed via user-data
│   ├── environments/
│   │   └── prod/                         # Production environment configuration
│   └── Makefile                          # Infrastructure automation targets
│
└── scripts/
    ├── install-argocd.sh                 # One-click ArgoCD installer with NodePort setup
    └── trigger-chaos-rca.sh              # Failure injection & automated RCA email test runner
```

---

## 🚀 Execution Guide: Step-by-Step

Follow these steps to deploy and run the entire platform from scratch.

### Prerequisites

- [AWS CLI v2](https://aws.amazon.com/cli/) configured (`aws configure`)
- [Terraform](https://www.terraform.io/) $\ge$ 1.7
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://www.docker.com/) (optional for local testing)
- [jq](https://stedolan.github.io/jq/) and `curl`

---

### Step 1: Provision Infrastructure with Terraform

#### 1.1 Bootstrap S3 State & DynamoDB Table
```bash
cd infra-terraform
make bootstrap
```
Note the bucket name and DynamoDB lock table printed in the outputs.

#### 1.2 Configure Production Variables
Edit `infra-terraform/environments/prod/backend.tf`:
```hcl
terraform {
  backend "s3" {
    bucket         = "<YOUR_BOOTSTRAP_BUCKET_NAME>"
    key            = "prod/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "<YOUR_BOOTSTRAP_LOCK_TABLE_NAME>"
    encrypt        = true
  }
}
```

Copy and update `terraform.tfvars`:
```bash
cp environments/prod/terraform.tfvars.example environments/prod/terraform.tfvars
```
Set the following keys in `terraform.tfvars`:
- `github_repo = "your-github-username/your-repo-name"`
- `ses_sender_email = "alerts@yourdomain.com"` (or an email address you verify in AWS SES)
- `ssh_allowed_cidrs = ["0.0.0.0/0"]` (or your public IP)
- `tfstate_bucket = "<YOUR_BOOTSTRAP_BUCKET_NAME>"`
- `tflock_table = "<YOUR_BOOTSTRAP_LOCK_TABLE_NAME>"`

#### 1.3 Deploy Cluster & Infrastructure
```bash
make init
make plan
make apply
```

The user-data script on EC2 automatically:
1. Installs Amazon Linux 2023 dependencies (`awscli`, `jq`, `curl`, `git`).
2. Installs `k3s` with Traefik enabled and the Elastic IP registered in its TLS SAN.
3. Uploads the patched remote `kubeconfig` directly to AWS SSM Parameter Store (`/ai-sre-agent/prod/k3s/kubeconfig`).
4. Installs the Kubernetes Metrics Server.

---

### Step 2: Configure Local Kubectl Access

Fetch your cluster kubeconfig automatically using AWS SSM:
```bash
make kubeconfig
```
Or export the kubeconfig manually:
```bash
export KUBECONFIG=~/.kube/ai-sre-agent-prod.yaml
kubectl get nodes -o wide
```
You should see your EC2 k3s node in `Ready` status.

---

### Step 3: Install ArgoCD on the Cluster

Run the automated ArgoCD installation script:
```bash
cd ..
./scripts/install-argocd.sh
```
This script:
- Creates the `argocd` namespace.
- Deploys official ArgoCD manifests.
- Exposes `argocd-server` on **NodePort 30443**.
- Fetches and displays the initial admin credentials.

Access the ArgoCD Web Dashboard:
- URL: `https://<EC2_PUBLIC_IP>:30443`
- Username: `admin`
- Password: `<printed by script>`

---

### Step 4: Configure Secrets & Email Notifications

Create the SRE Agent Kubernetes secret in the `ai-agent` namespace:
```bash
kubectl create namespace ai-agent --dry-run=client -o yaml | kubectl apply -f -

kubectl -n ai-agent create secret generic agent-secrets \
  --from-literal=anthropic_api_key="sk-ant-..." \
  --from-literal=agent_api_key="your-sre-secret-key" \
  --from-literal=smtp_host="smtp.gmail.com" \
  --from-literal=smtp_user="your-email@gmail.com" \
  --from-literal=smtp_pass="your-app-password"
```

> [!NOTE]
> - **Anthropic Key:** Optional! If you don't provide an Anthropic key, the SRE Agent's built-in **intelligent heuristic engine** automatically takes over to inspect logs, events, and exit codes to produce a complete RCA report.
> - **Email:** Supports both **AWS SES** (via the EC2 instance role) and standard **SMTP** (e.g., Gmail App Passwords, Mailgun, SendGrid).

---

### Step 5: Deploy Services via ArgoCD (GitOps)

1. Open `gitops/argocd/*.yaml` and ensure `repoURL` points to your GitHub repository:
   ```yaml
   source:
     repoURL: https://github.com/<your-username>/RCA_Platform.git
     targetRevision: HEAD
   ```
2. Apply the **App-of-Apps** master manifest:
   ```bash
   kubectl apply -f gitops/argocd/root-application.yaml
   ```
3. ArgoCD immediately detects the definitions and synchronizes:
   - `apps/namespaces.yaml`
   - `order-service` (NodePort 30081)
   - `product-service` (NodePort 30082)
   - `sre-agent` (NodePort 30080)

Verify running pods:
```bash
kubectl get pods -n apps
kubectl get pods -n ai-agent
```

---

### Step 6: Configure GitHub Actions CI/CD Pipeline

Add the following repository secrets to GitHub (**Settings → Secrets and variables → Actions**):
- `AWS_ROLE_ARN`: The GitHub Actions OIDC IAM role ARN (from `terraform output github_actions_role_arn`)
- `AWS_REGION`: `ap-south-1`

Whenever code is pushed to `main`:
1. GitHub Actions runs code syntax checks and tests.
2. Builds Docker images for changed microservices and pushes them to AWS ECR.
3. Automatically updates image tags in `gitops/apps/*/deployment.yaml` and commits the changes.
4. ArgoCD detects the commit and performs an automated zero-downtime rolling update.

---

### Step 7: Test Chaos Injection & Automated RCA Generation

We provide a turnkey script that triggers failures and runs the full RCA pipeline:

```bash
# Scenario 1: Process crash in order-service (CrashLoopBackOff)
./scripts/trigger-chaos-rca.sh crash-order your-email@example.com

# Scenario 2: Memory exhaustion in product-service (OOMKilled - Exit code 137)
./scripts/trigger-chaos-rca.sh oom-product your-email@example.com

# Scenario 3: Database pool exhaustion simulation
./scripts/trigger-chaos-rca.sh db-exhaustion your-email@example.com
```

#### What Happens Behind the Scenes:
1. The script calls the service's chaos endpoint (`/chaos/crash` or `/chaos/oom`).
2. Kubernetes detects the failure (CrashLoopBackOff or cgroup OOM termination).
3. The AI SRE Agent:
   - Calls `tools.get_pod_logs(..., previous=True)` to extract previous crash logs and stack traces.
   - Fetches Kubernetes warning events and termination exit codes.
   - Diagnoses the root cause using the LLM agent or heuristic analyzer.
   - Formulates immediate remediation commands (`kubectl rollout undo`, scale limits, etc.) and long-term prevention.
   - Renders a responsive **HTML RCA Report**.
   - Dispatches an **email notification** with the full HTML report **attached**.
4. You can view the live HTML report anytime in your browser at:
   `http://<EC2_PUBLIC_IP>:30080/rca/latest`

---

## 🛠️ Service Endpoints Reference

| Service | NodePort | Description | Key Endpoints |
|---|---|---|---|
| **ArgoCD UI** | `30443` | GitOps Management Dashboard | `https://<IP>:30443` |
| **SRE Agent** | `30080` | RCA Generator & Cluster Observer | `GET /rca/latest`<br>`POST /rca`<br>`POST /rca/auto-scan`<br>`POST /chat` |
| **Order Service** | `30081` | Order Processing Microservice | `GET /orders`<br>`POST /orders`<br>`POST /chaos/crash`<br>`POST /chaos/db-error` |
| **Product Service** | `30082` | Product Catalog Microservice | `GET /products`<br>`POST /chaos/oom`<br>`POST /chaos/latency` |

---

## 💻 CLI Usage

You can also run the SRE Agent directly from the command line:

```bash
cd services/sre-agent

# Scan cluster for unhealthy pods
python cli.py scan

# Perform RCA and send email
python cli.py rca --question "product-service is restarting" --email you@example.com

# Test email transmission and HTML attachment
python cli.py test-email --to you@example.com
```
