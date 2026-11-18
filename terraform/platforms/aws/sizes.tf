locals {
  # Supported OSes and their login users; spec.py, the scripts and the IDP read the same file.
  platform = jsondecode(file("${path.module}/platform.json"))
  os       = local.platform.os[var.os]
  # Single source of truth for size -> instance type, per OS family; the IDP reads the same file.
  sizes         = jsondecode(file("${path.module}/sizes.json"))
  instance_type = var.instance_type != "" ? var.instance_type : local.sizes[local.os.family][var.size]
  # Inventory from before image versions were recorded is the OS's first (original) release.
  image_version = coalesce(var.image_version, local.os.versions[0])
}
