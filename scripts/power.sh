#!/usr/bin/env bash
# start | stop | reboot one VM instance. Idempotent: an instance already in the target state succeeds.
set -euo pipefail
action=${1:?start, stop or reboot}
[[ "$action" =~ ^(start|stop|reboot)$ ]] || exit 1
id=${INSTANCE_ID:?}
user=${SSH_USER:-ubuntu}
key="${RUNNER_TEMP:?}/cf-key"
describe() { aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0]' --output json; }
instance=$(describe)
# Only the instance launched for this VM incarnation.
jq -e --arg name "${NAME:?}" --arg request "${REQUEST_ID:?}" \
  '(.Tags // []) | from_entries | .["cf:vm"] == $name and .["cf:request-id"] == $request and .["cf:poc"] == "true"' \
  <<< "$instance" >/dev/null || { echo "Instance $id does not belong to $NAME" >&2; exit 1; }
state=$(jq -r '.State.Name' <<< "$instance")
echo "Instance $id is $state"
remote() {
  ssh -i "$key" -o "CertificateFile=$key-cert.pub" -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$user@$1" "${@:2}"
}
case "$action" in
  stop)
    if [[ "$state" != stopped ]]; then
      aws ec2 stop-instances --instance-ids "$id" >/dev/null
      aws ec2 wait instance-stopped --instance-ids "$id"
    fi
    PUBLIC_IP='' bash scripts/inventory.sh address
    ;;
  start)
    if [[ "$state" != running ]]; then
      [[ "$state" != stopping ]] || aws ec2 wait instance-stopped --instance-ids "$id"
      aws ec2 start-instances --instance-ids "$id" >/dev/null
      aws ec2 wait instance-running --instance-ids "$id"
    fi
    ip=$(describe | jq -r '.PublicIpAddress // ""')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Started instance has no public IP' >&2; exit 1; }
    PUBLIC_IP=$ip bash scripts/inventory.sh address
    bash scripts/ssh-ca.sh "$key"
    bash scripts/wait-for-ssh.sh "$ip" "$user" "$key"
    ;;
  reboot)
    [[ "$state" == running ]] || { echo "Cannot reboot a $state instance; start it instead" >&2; exit 1; }
    ip=$(jq -r '.PublicIpAddress // ""' <<< "$instance")
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Instance has no public IP' >&2; exit 1; }
    bash scripts/ssh-ca.sh "$key"
    # The boot ID changes on every boot; an unreachable (hung) guest is still rebooted.
    before=$(remote "$ip" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
    aws ec2 reboot-instances --instance-ids "$id"
    deadline=$((SECONDS + 600))
    sleep 15
    until after=$(remote "$ip" cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [[ -n "$after" && "$after" != "$before" ]]; do
      (( SECONDS < deadline )) || { echo 'The VM did not come back within 10 minutes' >&2; exit 1; }
      sleep 10
    done
    echo "Rebooted; boot ID $after"
    ;;
esac
