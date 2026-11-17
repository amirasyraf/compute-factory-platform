#!/usr/bin/env bash
set -euo pipefail
action=${1:?apply or destroy}
[[ "$action" == apply || "$action" == destroy ]] || exit 1
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || exit 1
file="${INVENTORY_ROOT:-.}/vms/$NAME/catalog-info.yaml"
[[ "$action" != destroy || -f "$file" ]] || exit 0
[[ "$(yq -r '.metadata.annotations."cf/request-id"' "$file")" == "${REQUEST_ID:?}" ]] || exit 1
# shellcheck source=scripts/load-spec.sh
source "$(dirname "$0")/load-spec.sh"
load_spec
dir="terraform/platforms/$PLATFORM"
key="vms/$PLATFORM/$NAME/terraform.tfstate"
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cf-terraform.XXXXXX")
trap 'rm -f "$scratch"/*; rmdir "$scratch"' EXIT
chmod 700 "$scratch"
vars_file="$scratch/vm.tfvars.json"
requested_by=$(yq -r '.metadata.annotations."cf/requested-by"' "$file")
jq --arg name "$NAME" --arg user "$requested_by" --arg request "$REQUEST_ID" \
  '{name:$name,os:.compute.os,size:(.compute.size // "S"),instance_type:(.compute.instanceType // ""),team:(.owner|split("/")[-1]),requested_by:$user,request_id:$request,
    cloud_tags:(.cloudTags + (.billing | with_entries(.key = (if .key=="costCenter" then "cost_center" else "project_code" end))))}' \
  <<< "$SPEC_JSON" > "$vars_file"
terraform -chdir="$dir" init -input=false -lockfile=readonly \
  -backend-config="bucket=${TF_STATE_BUCKET:?}" -backend-config="key=$key" \
  -backend-config="region=${AWS_REGION:?}" -backend-config=use_lockfile=true
# Listing distinguishes a missing lock from auth/network errors (which must fail closed).
objects=$(aws s3api list-objects-v2 --bucket "$TF_STATE_BUCKET" --prefix "$key" --output json)
if jq -e --arg key "$key.tflock" 'any(.Contents[]?; .Key == $key)' <<< "$objects" >/dev/null; then
  aws s3api get-object --bucket "$TF_STATE_BUCKET" --key "$key.tflock" "$scratch/lock.json" >/dev/null
  age=$(python3 - "$scratch/lock.json" <<'PY'
import datetime, json, sys
lock = json.load(open(sys.argv[1]))
created = datetime.datetime.fromisoformat(lock['Created'].replace('Z', '+00:00'))
print(int((datetime.datetime.now(datetime.timezone.utc) - created).total_seconds()))
PY
)
  if (( age > 1200 )); then
    lock_id=$(jq -er '.ID | select(type == "string" and length > 0)' "$scratch/lock.json")
    echo "Unlocking stale state lock $lock_id (${age}s old; VM stages serialized)"
    terraform -chdir="$dir" force-unlock -force "$lock_id"
  else
    echo "State lock is ${age}s old; refusing to unlock a potentially active operation" >&2
    exit 1
  fi
fi
# Recover resources created before a runner lost its state write. Never guess among duplicates.
tracked=''
if jq -e --arg key "$key" 'any(.Contents[]?; .Key == $key)' <<< "$objects" >/dev/null; then
  tracked=$(terraform -chdir="$dir" state list)
fi
filters=("Name=tag:cf:vm,Values=$NAME" "Name=tag:cf:request-id,Values=$REQUEST_ID" "Name=tag:cf:poc,Values=true")
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
if [[ "$action" == apply ]]; then
  STATUS=provisioning bash scripts/inventory.sh update
  terraform -chdir="$dir" plan -input=false -var-file="$vars_file" -out="$scratch/plan"
  terraform -chdir="$dir" show -json "$scratch/plan" > "$scratch/plan.json"
  # Unexpected replacement is not a safe retry. Leave the existing VM for an operator.
  jq -e 'all(.resource_changes[]?; (.change.actions | index("delete")) == null)' "$scratch/plan.json" >/dev/null \
    || { echo 'Refusing destructive provision plan; operator recovery required' >&2; exit 1; }
  terraform -chdir="$dir" apply -input=false -auto-approve "$scratch/plan"
  PUBLIC_IP=$(terraform -chdir="$dir" output -raw public_ip)
  SSH_USER=$(terraform -chdir="$dir" output -raw ssh_user)
  INSTANCE_ID=$(terraform -chdir="$dir" output -raw instance_id)
  INSTANCE_TYPE=$(terraform -chdir="$dir" output -raw instance_type)
  export PUBLIC_IP SSH_USER INSTANCE_ID INSTANCE_TYPE
  bash scripts/inventory.sh outputs
  STATUS=frying bash scripts/inventory.sh update
else
  STATUS=destroying bash scripts/inventory.sh update
  terraform -chdir="$dir" destroy -input=false -auto-approve -var-file="$vars_file"
  aws s3api delete-object --bucket "$TF_STATE_BUCKET" --key "$key"
  bash scripts/inventory.sh delete
fi
