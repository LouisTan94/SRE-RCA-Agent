# ArgoCD, trimmed for a laptop: no Dex, no notifications, no ApplicationSet controller,
# and modest resource limits (about 1.2-1.5 GB in total).
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    configs = {
      params = {
        "server.insecure" = true # plain HTTP behind kubectl port-forward
      }
      cm = {
        "timeout.reconciliation" = "${var.argocd_reconcile_seconds}s"
      }
    }

    dex           = { enabled = false }
    notifications = { enabled = false }
    applicationSet = { replicas = 0 }

    controller = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
    repoServer = {
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }
    server = {
      resources = {
        requests = { cpu = "25m", memory = "64Mi" }
        limits   = { cpu = "250m", memory = "256Mi" }
      }
    }
    redis = {
      resources = {
        requests = { cpu = "25m", memory = "32Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }
  })]

  depends_on = [minikube_cluster.this]
}

# Lets ArgoCD read the platform repo in the in-cluster Gitea.
resource "kubernetes_secret_v1" "argocd_repo" {
  metadata {
    name      = "repo-platform"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = local.repo_url_in_cluster
    username = var.gitea_admin_user
    password = random_password.gitea_admin.result
  }

  depends_on = [helm_release.argocd]
}

# Root "app of apps": it reads tier1/gitops/apps/ and creates one ArgoCD
# Application per service. Installed through a chart so Terraform doesn't need the
# Application CRD to exist at plan time.
resource "helm_release" "root_app" {
  name       = "root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = local.repo_url_in_cluster
          targetRevision = "main"
          path           = "tier1/gitops/apps"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]

  depends_on = [kubernetes_secret_v1.argocd_repo]
}
