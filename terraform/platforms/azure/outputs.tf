output "public_ip" {
  value = azurerm_public_ip.vm.ip_address
}

output "ssh_user" {
  value = local.os.sshUser
}

output "instance_id" {
  value = one(concat(azurerm_linux_virtual_machine.vm[*].id, azurerm_windows_virtual_machine.vm[*].id))
}

output "instance_type" {
  value = one(concat(azurerm_linux_virtual_machine.vm[*].size, azurerm_windows_virtual_machine.vm[*].size))
}
