#!/usr/bin/env bash
# EC2 power primitives, sourced by scripts/power.sh with INSTANCE_ID set.
# vm_describe prints {state, ip, tags}; state is pending|running|stopping|stopped|<other>.
vm_describe() {
  aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0]' --output json \
    | jq -c '{state: .State.Name, ip: (.PublicIpAddress // ""), tags: ((.Tags // []) | from_entries)}'
}
vm_stop() {
  aws ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
  aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
}
vm_start() {
  [[ "$(vm_describe | jq -r .state)" != stopping ]] || aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
}
vm_reboot() { aws ec2 reboot-instances --instance-ids "$INSTANCE_ID"; }
