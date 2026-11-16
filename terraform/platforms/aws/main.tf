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

data "aws_ec2_instance_type" "selected" {
  instance_type = local.instance_type
}

# Not every type is offered in every AZ; launch only into a default subnet whose AZ offers it.
data "aws_ec2_instance_type_offerings" "selected" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [local.instance_type]
  }
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
  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.selected.locations
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
  instance_type               = local.instance_type
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
  lifecycle {
    precondition {
      condition     = contains(data.aws_ec2_instance_type.selected.supported_architectures, "x86_64")
      error_message = "${local.instance_type} cannot boot the x86_64 golden image."
    }
    precondition {
      condition     = length(data.aws_subnets.default.ids) > 0
      error_message = "${local.instance_type} is not offered in any default-subnet AZ in this region."
    }
  }
}
