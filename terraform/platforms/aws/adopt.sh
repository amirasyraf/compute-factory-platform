#!/usr/bin/env bash
# Adopt resources created before a runner lost its state write. Never guess among duplicates.
# Called by scripts/terraform.sh: adopt.sh <vars-file> <tracked state addresses>
set -euo pipefail
vars_file=${1:?vars file}
tracked=${2-}
dir=$(dirname "$0")
filters=("Name=tag:cf:vm,Values=${NAME:?}" "Name=tag:cf:request-id,Values=${REQUEST_ID:?}" "Name=tag:cf:poc,Values=true")
if ! grep -qx 'aws_security_group.vm' <<< "$tracked"; then
  groups=$(aws ec2 describe-security-groups --filters "${filters[@]}" --query 'SecurityGroups[].GroupId' --output json)
  count=$(jq 'length' <<< "$groups")
  (( count <= 1 )) || { echo 'Multiple orphan security groups; operator recovery required' >&2; exit 1; }
  if (( count == 1 )); then
    id=$(jq -r '.[0]' <<< "$groups")
    echo "Adopting orphan security group $id for $NAME/$REQUEST_ID"
    terraform -chdir="$dir" import -input=false -var-file="$vars_file" aws_security_group.vm "$id"
  fi
fi
if ! grep -qx 'aws_instance.vm' <<< "$tracked"; then
  instances=$(aws ec2 describe-instances --filters "${filters[@]}" 'Name=instance-state-name,Values=pending,running,stopping,stopped' --query 'Reservations[].Instances[].InstanceId' --output json)
  count=$(jq 'length' <<< "$instances")
  (( count <= 1 )) || { echo 'Multiple orphan instances; operator recovery required' >&2; exit 1; }
  if (( count == 1 )); then
    id=$(jq -r '.[0]' <<< "$instances")
    echo "Adopting orphan instance $id for $NAME/$REQUEST_ID"
    terraform -chdir="$dir" import -input=false -var-file="$vars_file" aws_instance.vm "$id"
  fi
fi
