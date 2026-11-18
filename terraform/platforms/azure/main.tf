terraform {
  required_version = ">= 1.10, < 2.0"
  # Same S3 state bucket as every platform (vms/azure/<name>/terraform.tfstate).
  backend "s3" {}
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Credentials and subscription come from ARM_* (OIDC in GitHub Actions, the cf-admin-local
# certificate on the laptop). The resource providers are registered once per subscription.
provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}

data "azurerm_client_config" "current" {}

locals {
  sizes         = jsondecode(file("${path.module}/sizes.json"))
  platform      = jsondecode(file("${path.module}/platform.json"))
  instance_type = var.instance_type != "" ? var.instance_type : local.sizes[var.size]
  # Every resource of one VM lives in its own resource group with fixed names, so recovery
  # (adopt.sh) and teardown find them without guessing.
  resource_group = "cf-vm-${var.name}"
  resource_name  = "cf-${var.name}"
  tags = merge(var.cloud_tags, var.request_id == "" ? {} : { "cf:request-id" = var.request_id }, {
    "cf:poc"  = "true"
    "cf:vm"   = var.name
    "cf:team" = var.team
  })
  # Latest version of the OS's image definition in the infra gallery (published by the bake).
  image_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/cf-images/providers/Microsoft.Compute/galleries/cfimages/images/${var.os}"
}

resource "azurerm_resource_group" "vm" {
  name     = local.resource_group
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "vm" {
  name                = local.resource_name
  resource_group_name = azurerm_resource_group.vm.name
  location            = azurerm_resource_group.vm.location
  address_space       = ["10.80.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "vm" {
  name                 = local.resource_name
  resource_group_name  = azurerm_resource_group.vm.name
  virtual_network_name = azurerm_virtual_network.vm.name
  address_prefixes     = ["10.80.1.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  name                = local.resource_name
  resource_group_name = azurerm_resource_group.vm.name
  location            = azurerm_resource_group.vm.location
  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  tags = local.tags
}

# Static: the address survives stop (deallocate) and resize.
resource "azurerm_public_ip" "vm" {
  name                = local.resource_name
  resource_group_name = azurerm_resource_group.vm.name
  location            = azurerm_resource_group.vm.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "vm" {
  name                = local.resource_name
  resource_group_name = azurerm_resource_group.vm.name
  location            = azurerm_resource_group.vm.location
  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
  tags = local.tags
}

resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# Azure requires an admin key. Logins use the SSH CA only: the fry `access` stage turns off
# authorized_keys, so this key (kept only in the Terraform state) cannot be used after the first fry.
resource "tls_private_key" "admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                            = local.resource_name
  resource_group_name             = azurerm_resource_group.vm.name
  location                        = azurerm_resource_group.vm.location
  size                            = local.instance_type
  admin_username                  = local.platform.os[var.os].sshUser
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]
  source_image_id                 = local.image_id
  admin_ssh_key {
    username   = local.platform.os[var.os].sshUser
    public_key = tls_private_key.admin.public_key_openssh
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  tags = merge(local.tags, { "cf:requested-by" = var.requested_by })
  lifecycle {
    # Creation-time choices: a newer bake or a re-created key after adoption must not replace the VM.
    ignore_changes = [source_image_id, admin_ssh_key]
  }
}
