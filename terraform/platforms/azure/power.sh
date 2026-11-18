#!/usr/bin/env bash
# Azure power primitives, sourced by scripts/power.sh with INSTANCE_ID (the VM's ARM ID) set.
# vm_describe prints {state, ip, tags}. Stop deallocates, so a stopped VM is not billed for compute;
# a guest-initiated shutdown (allocated, still billed) is "stopped-allocated", which stop deallocates.
vm_describe() {
  local view ip
  view=$(az vm get-instance-view --ids "$INSTANCE_ID" -o json)
  ip=$(az network public-ip show --ids "${INSTANCE_ID%/providers/*}/providers/Microsoft.Network/publicIPAddresses/${INSTANCE_ID##*/}" \
    --query 'ipAddress' -o tsv 2>/dev/null || true)
  jq -c --arg ip "$ip" '
    ([.instanceView.statuses[]?.code] ) as $codes
    | (($codes | map(select(startswith("PowerState/")))[0] // "PowerState/unknown") | ltrimstr("PowerState/")) as $power
    | {state: (if any($codes[]; . == "ProvisioningState/deleting") then "shutting-down"
               else {starting: "pending", running: "running", stopping: "stopping", deallocating: "stopping",
                     deallocated: "stopped", stopped: "stopped-allocated"}[$power] // $power end),
       ip: $ip, tags: (.tags // {})}' <<< "$view"
}
vm_stop() { az vm deallocate --ids "$INSTANCE_ID" -o none; }
vm_start() { az vm start --ids "$INSTANCE_ID" -o none; }
vm_reboot() { az vm restart --ids "$INSTANCE_ID" -o none; }
