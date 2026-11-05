# Gitea: the in-cluster Git server ArgoCD pulls from, and where the coding agents open PRs.
# SQLite, single replica, about 0.3-0.4 GB of RAM.

resource "random_password" "gitea_admin" {
  length  = 24
  special = false
}

locals {
  gitea_ns            = "gitea"
  repo_url_in_cluster = "http://gitea-http.${local.gitea_ns}.svc.cluster.local:3000/${var.gitea_admin_user}/${var.gitea_repo_name}.git"
}

resource "kubernetes_namespace_v1" "gitea" {
  metadata {
    name = local.gitea_ns
  }
  depends_on = [minikube_cluster.this]
}

resource "kubernetes_persistent_volume_claim_v1" "gitea" {
  metadata {
    name      = "gitea-data"
    namespace = local.gitea_ns
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = "2Gi" }
    }
  }
  wait_until_bound = false
  depends_on       = [kubernetes_namespace_v1.gitea]
}

resource "kubernetes_deployment_v1" "gitea" {
  metadata {
    name      = "gitea"
    namespace = local.gitea_ns
    labels    = { app = "gitea" }
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" } # RWO volume

    selector {
      match_labels = { app = "gitea" }
    }

    template {
      metadata {
        labels = { app = "gitea" }
      }

      spec {
        security_context {
          fs_group = 1000
        }

        # minikube's hostPath volumes ignore fsGroup, so prepare the directories
        # the rootless Gitea user (uid 1000) needs before it starts.
        init_container {
          name    = "prepare-volume"
          image   = "busybox:1.36"
          command = ["sh", "-c", "mkdir -p /vol/data /vol/config && chown -R 1000:1000 /vol"]
          volume_mount {
            name       = "data"
            mount_path = "/vol"
          }
        }

        container {
          name  = "gitea"
          image = var.gitea_image

          port {
            name           = "http"
            container_port = 3000
          }

          # GITEA__section__KEY env vars are written into app.ini on start.
          env {
            name  = "GITEA__security__INSTALL_LOCK"
            value = "true"
          }
          env {
            name  = "GITEA__database__DB_TYPE"
            value = "sqlite3"
          }
          env {
            name  = "GITEA__server__HTTP_PORT"
            value = "3000"
          }
          env {
            name  = "GITEA__server__ROOT_URL"
            value = "http://localhost:3000/"
          }
          env {
            name  = "GITEA__server__OFFLINE_MODE"
            value = "true"
          }
          env {
            name  = "GITEA__server__DISABLE_SSH"
            value = "true"
          }
          env {
            name  = "GITEA__service__DISABLE_REGISTRATION"
            value = "true"
          }
          env {
            name  = "GITEA__repository__DEFAULT_BRANCH"
            value = "main"
          }
          env {
            name  = "GITEA__actions__ENABLED"
            value = "false" # CI runs from tier1/scripts/ci.sh on the host instead
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/gitea"
            sub_path   = "data"
          }
          volume_mount {
            name       = "data"
            mount_path = "/etc/gitea"
            sub_path   = "config"
          }

          readiness_probe {
            http_get {
              path = "/api/healthz"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.gitea.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_rollout = true
  timeouts {
    create = "10m"
  }
}

resource "kubernetes_service_v1" "gitea" {
  metadata {
    name      = "gitea-http"
    namespace = local.gitea_ns
  }
  spec {
    selector = { app = "gitea" }
    port {
      name        = "http"
      port        = 3000
      target_port = 3000
    }
  }
  depends_on = [kubernetes_namespace_v1.gitea]
}
