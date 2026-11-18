output "public_ip" {
  value = azurerm_public_ip.vm.ip_address
}

output "ssh_user" {
  value = local.platform.os[var.os].sshUser
}

output "instance_id" {
  value = azurerm_linux_virtual_machine.vm.id
}

output "instance_type" {
  value = azurerm_linux_virtual_machine.vm.size
}
