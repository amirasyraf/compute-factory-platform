#!/usr/bin/env bash
# start | stop | reboot one VM. Idempotent: a VM already in the target state succeeds.
# Cloud calls come from terraform/platforms/$PLATFORM/power.sh (vm_describe, vm_start, vm_stop, vm_reboot).
set -euo pipefail
action=${1:?start, stop or reboot}
[[ "$action" =~ ^(start|stop|reboot)$ ]] || exit 1
: "${INSTANCE_ID:?}"
user=${SSH_USER:?}
key="${RUNNER_TEMP:?}/cf-key"
# shellcheck source=/dev/null
source "terraform/platforms/${PLATFORM:?}/power.sh"
instance=$(vm_describe)
# Only the instance launched for this VM incarnation.
jq -e --arg name "${NAME:?}" --arg request "${REQUEST_ID:?}" \
  '.tags["cf:vm"] == $name and .tags["cf:request-id"] == $request and .tags["cf:poc"] == "true"' \
  <<< "$instance" >/dev/null || { echo "Instance $INSTANCE_ID does not belong to $NAME" >&2; exit 1; }
state=$(jq -r '.state' <<< "$instance")
echo "Instance $INSTANCE_ID is $state"
remote() {
  ssh -i "$key" -o "CertificateFile=$key-cert.pub" -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$user@$1" "${@:2}"
}
case "$action" in
  stop)
    [[ "$state" == stopped ]] || vm_stop
    PUBLIC_IP='' bash scripts/inventory.sh address
    ;;
  start)
    [[ "$state" == running ]] || vm_start
    ip=$(vm_describe | jq -r '.ip')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Started instance has no public IP' >&2; exit 1; }
    PUBLIC_IP=$ip bash scripts/inventory.sh address
    bash scripts/ssh-ca.sh "$key"
    bash scripts/wait-for-ssh.sh "$ip" "$user" "$key"
    ;;
  reboot)
    [[ "$state" == running ]] || { echo "Cannot reboot a $state instance; start it instead" >&2; exit 1; }
    ip=$(jq -r '.ip' <<< "$instance")
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Instance has no public IP' >&2; exit 1; }
    bash scripts/ssh-ca.sh "$key"
    # The boot ID changes on every boot; an unreachable (hung) guest is still rebooted.
    before=$(remote "$ip" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
    vm_reboot
    deadline=$((SECONDS + 600))
    sleep 15
    until after=$(remote "$ip" cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [[ -n "$after" && "$after" != "$before" ]]; do
      (( SECONDS < deadline )) || { echo 'The VM did not come back within 10 minutes' >&2; exit 1; }
      sleep 10
    done
    echo "Rebooted; boot ID $after"
    ;;
esac
