# -----------------------------------------------------------------------------
# prod inputs. Diff this against ../dev/terraform.tfvars: the differences are
# the whole story of what "production" means here.
#
#   desired_count  1 -> 2      the module's precondition refuses 1 in prod
#   image tags     older -> promoted-after-soak, never :latest
#   worker         present in both, still private in both
# -----------------------------------------------------------------------------

services = {
  api = {
    image         = "canon/api:1.4.1" # one release behind dev: promotion is deliberate
    cpu           = 512
    memory        = 1024
    desired_count = 3
    public        = true
    ports         = [443, 8443]
    health_path   = "/healthz"
  }

  web = {
    image         = "canon/web:2.0.9"
    cpu           = 512
    memory        = 1024
    desired_count = 2
    public        = true
    ports         = [443]
    health_path   = "/"
  }

  worker = {
    image         = "canon/worker:0.9.0"
    cpu           = 512
    memory        = 1024
    desired_count = 2
  }
}

tags = {
  Owner        = "platform-engineering"
  CostCenter   = "cc-1234"
  DataClass    = "confidential"
  BackupPolicy = "daily-35d"
}
