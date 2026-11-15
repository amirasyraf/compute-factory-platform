locals {
  # Single source of truth for size -> instance type; the IDP reads the same file to label sizes.
  sizes = jsondecode(file("${path.module}/sizes.json"))
  ssh_users = {
    ubuntu = "ubuntu"
  }
}
