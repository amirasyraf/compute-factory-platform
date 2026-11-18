#!/usr/bin/env bash
# Adopt resources created before a runner lost its state write.
# Called by scripts/terraform.sh: adopt.sh <vars-file> <tracked state addresses>
# All resources have fixed names in resource group cf-vm-<name>; it must belong to this incarnation.
set -euo pipefail
vars_file=${1:?vars file}
tracked=${2-}
dir=$(dirname "$0")
group="cf-vm-${NAME:?}"
res="cf-$NAME"
[[ "$(az group exists -n "$group")" == true ]] || exit 0
tags=$(az group show -n "$group" --query tags -o json)
jq -e --arg name "$NAME" --arg request "${REQUEST_ID:?}" \
  '.["cf:vm"] == $name and .["cf:request-id"] == $request and .["cf:poc"] == "true"' <<< "$tags" >/dev/null \
  || { echo "Resource group $group belongs to another VM incarnation; operator recovery required" >&2; exit 1; }
sub=$(az account show --query id -o tsv)
base="/subscriptions/$sub/resourceGroups/$group"
existing=$(az resource list -g "$group" --query '[].id' -o tsv | tr '[:upper:]' '[:lower:]')
nic="$base/providers/Microsoft.Network/networkInterfaces/$res"
nsg="$base/providers/Microsoft.Network/networkSecurityGroups/$res"
vnet="$base/providers/Microsoft.Network/virtualNetworks/$res"
adopt() { # <address> <id> <exists: true|false>
  grep -Fqx "$1" <<< "$tracked" && return 0
  [[ "$3" == true ]] || return 0
  echo "Adopting $1 ($2)"
  terraform -chdir="$dir" import -input=false -var-file="$vars_file" "$1" "$2"
}
has() { grep -Fqx "$(tr '[:upper:]' '[:lower:]' <<< "$1")" <<< "$existing" && echo true || echo false; }
adopt azurerm_resource_group.vm "$base" true
adopt azurerm_virtual_network.vm "$vnet" "$(has "$vnet")"
subnet_exists=false
if [[ "$(has "$vnet")" == true ]] && az network vnet subnet show --ids "$vnet/subnets/$res" -o none 2>/dev/null; then subnet_exists=true; fi
adopt azurerm_subnet.vm "$vnet/subnets/$res" "$subnet_exists"
adopt azurerm_network_security_group.vm "$nsg" "$(has "$nsg")"
adopt azurerm_public_ip.vm "$base/providers/Microsoft.Network/publicIPAddresses/$res" "$(has "$base/providers/Microsoft.Network/publicIPAddresses/$res")"
adopt azurerm_network_interface.vm "$nic" "$(has "$nic")"
associated=false
if [[ "$(has "$nic")" == true && -n "$(az network nic show --ids "$nic" --query 'networkSecurityGroup.id' -o tsv)" ]]; then associated=true; fi
adopt azurerm_network_interface_security_group_association.vm "$nic|$nsg" "$associated"
vm="$base/providers/Microsoft.Compute/virtualMachines/$res"
adopt azurerm_linux_virtual_machine.vm "$vm" "$(has "$vm")"
