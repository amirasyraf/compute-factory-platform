terraform {
  required_version = ">= 1.10, < 2.0"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  default_tags {
    tags = merge(var.cloud_tags, {
      "cf:poc"  = "true"
      "cf:vm"   = var.name
      "cf:team" = var.team
    })
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ami" "golden" {
  most_recent = true
  owners      = ["self"]
  filter {
    name   = "tag:cf:os"
    values = [var.os]
  }
  filter {
    name   = "tag:cf:managed"
    values = ["true"]
  }
}

resource "aws_security_group" "vm" {
  name_prefix = "cf-${var.name}-"
  description = "Compute Factory ${var.name} SSH (POC)"
  vpc_id      = data.aws_vpc.default.id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "cf-${var.name}" }
}

resource "aws_instance" "vm" {
  ami                         = data.aws_ami.golden.id
  instance_type               = local.sizes[var.size]
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.vm.id]
  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 16
    encrypted             = true
    delete_on_termination = true
  }
  tags = {
    Name              = "cf-${var.name}"
    "cf:requested-by" = var.requested_by
  }
}
