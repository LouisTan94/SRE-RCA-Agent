variable "cluster_name" {
  description = "minikube profile name (also the kubectl context name)."
  type        = string
  default     = "sre-tier1"
}

variable "kubernetes_version" {
  description = "Kubernetes version for minikube ('stable' = minikube's default)."
  type        = string
  default     = "stable"
}

variable "cpus" {
  description = "CPUs for the minikube node. Tier 1 sizing: 4."
  type        = number
  default     = 4
}

variable "memory" {
  description = "Memory for the minikube node. Tier 1 sizing: 6g."
  type        = string
  default     = "6g"
}

variable "disk_size" {
  description = "Disk for the minikube node."
  type        = string
  default     = "30g"
}

variable "argocd_chart_version" {
  description = "argo-helm 'argo-cd' chart version."
  type        = string
  default     = "10.12.1"
}

variable "argocd_apps_chart_version" {
  description = "argo-helm 'argocd-apps' chart version."
  type        = string
  default     = "2.0.7"
}

variable "gitea_image" {
  description = "Gitea image (rootless variant)."
  type        = string
  default     = "gitea/gitea:1.27.3-rootless"
}

variable "gitea_admin_user" {
  description = "Gitea admin user that owns the platform repo. ArgoCD and the scripts use it."
  type        = string
  default     = "sdlc"
}

variable "gitea_repo_name" {
  description = "Repo in Gitea that ArgoCD watches."
  type        = string
  default     = "platform"
}

variable "argocd_reconcile_seconds" {
  description = "How often ArgoCD polls Git. The verify script also forces a refresh after each push."
  type        = number
  default     = 60
}
