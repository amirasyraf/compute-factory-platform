output "public_ip" {
  value = aws_instance.vm.public_ip
}

output "ssh_user" {
  value = local.platform.os[var.os].sshUser
}

output "instance_id" {
  value = aws_instance.vm.id
}

output "instance_type" {
  value = aws_instance.vm.instance_type
}
