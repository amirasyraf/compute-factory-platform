locals {
  # Single source of truth for size -> instance type; the IDP reads the same file to label sizes.
  sizes         = jsondecode(file("${path.module}/sizes.json"))
  instance_type = var.instance_type != "" ? var.instance_type : local.sizes[var.size]
  # Supported OSes and their login users; spec.py, the scripts and the IDP read the same file.
  platform = jsondecode(file("${path.module}/platform.json"))
}
