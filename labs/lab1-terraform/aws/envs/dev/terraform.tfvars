# -----------------------------------------------------------------------------
# dev inputs. THIS is the file a routine change request edits - one map, no code.
#
# Compare with ../prod/terraform.tfvars: same shape, different values. Every
# structural difference between the environments is a deliberate one, expressed
# as data, and a reviewer can diff the two files to see all of it at once.
# -----------------------------------------------------------------------------

services = {
  api = {
    image         = "canon/api:1.4.2"
    cpu           = 256
    memory        = 512
    desired_count = 1 # dev tolerates one task; prod's precondition refuses it
    public        = true
    ports         = [443, 8443]
    health_path   = "/healthz"
  }

  web = {
    image         = "canon/web:2.1.0"
    cpu           = 256
    memory        = 512
    desired_count = 1
    public        = true
    ports         = [443]
    health_path   = "/"
  }

  # A private worker: no ports, not public. It gets a task definition, a
  # service, a log group, a task role and alarms - and no target group, no
  # listener rule and no DNS record, because the filtered for_each in the module
  # simply has no entry for it.
  worker = {
    image         = "canon/worker:0.9.1"
    cpu           = 256
    memory        = 512
    desired_count = 1
  }
}

tags = {
  Owner      = "platform-engineering"
  CostCenter = "cc-1234"
}
