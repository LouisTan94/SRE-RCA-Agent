terraform {
  required_version = ">= 1.6"

  required_providers {
    minikube = {
      source  = "scott-the-programmer/minikube"
      version = "~> 0.8"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30, < 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "minikube" {
  kubernetes_version = var.kubernetes_version
}

# Both providers talk to the cluster Terraform just created, using its outputs.
provider "kubernetes" {
  host                   = minikube_cluster.this.host
  client_certificate     = minikube_cluster.this.client_certificate
  client_key             = minikube_cluster.this.client_key
  cluster_ca_certificate = minikube_cluster.this.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = minikube_cluster.this.host
    client_certificate     = minikube_cluster.this.client_certificate
    client_key             = minikube_cluster.this.client_key
    cluster_ca_certificate = minikube_cluster.this.cluster_ca_certificate
  }
}
