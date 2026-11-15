output "public_ip" {
  value = aws_instance.vm.public_ip
}

output "ssh_user" {
  value = local.ssh_users[var.os]
}

output "instance_id" {
  value = aws_instance.vm.id
}
