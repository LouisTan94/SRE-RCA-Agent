output "cluster_name" {
  description = "minikube profile and kubectl context."
  value       = minikube_cluster.this.cluster_name
}

output "gitea_admin_user" {
  value = var.gitea_admin_user
}

output "gitea_admin_password" {
  description = "Read by the scripts with `terraform output -raw gitea_admin_password`."
  value       = random_password.gitea_admin.result
  sensitive   = true
}

output "gitea_repo" {
  value = "${var.gitea_admin_user}/${var.gitea_repo_name}"
}

output "repo_url_in_cluster" {
  value = local.repo_url_in_cluster
}
