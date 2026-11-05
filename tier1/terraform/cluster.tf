# One single-node minikube cluster on Docker (Tier 1: 4 CPU / 6 GB).
resource "minikube_cluster" "this" {
  cluster_name = var.cluster_name
  driver       = "docker"
  cpus         = tostring(var.cpus)
  memory       = var.memory
  disk_size    = var.disk_size

  addons = [
    "default-storageclass",
    "storage-provisioner",
    "metrics-server", # lets the SRE agent read CPU/memory usage
  ]
}
