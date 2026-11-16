#!/usr/bin/env bash
set -euo pipefail
action=${1:?apply or destroy}
[[ "$action" == apply || "$action" == destroy ]] || exit 1
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || exit 1
# shellcheck source=scripts/load-spec.sh
source "$(dirname "$0")/load-spec.sh"
load_spec
dir="terraform/platforms/$PLATFORM"
key="vms/$PLATFORM/$NAME/terraform.tfstate"
if [[ "$action" == apply ]]; then
  STATUS=provisioning STAGE=provision STAGE_STATUS=running bash scripts/inventory.sh update
fi
terraform -chdir="$dir" init -input=false -lockfile=readonly \
  -backend-config="bucket=${TF_STATE_BUCKET:?}" -backend-config="key=$key" \
  -backend-config="region=${AWS_REGION:?}" -backend-config=use_lockfile=true
if [[ "$action" == apply ]]; then
  vars_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cf-tfvars.XXXXXX")
  vars_file="$vars_dir/vm.tfvars.json"
  trap 'rm -f "$vars_file"; rmdir "$vars_dir"' EXIT
  requested_by=$(yq -r '.metadata.annotations."cf/requested-by"' "vms/$NAME/catalog-info.yaml")
  jq --arg name "$NAME" --arg user "$requested_by" \
    '{name:$name,os:.compute.os,size:(.compute.size // "S"),instance_type:(.compute.instanceType // ""),team:(.owner|split("/")[-1]),requested_by:$user,
      cloud_tags:(.cloudTags + (.billing | with_entries(.key = (if .key=="costCenter" then "cost_center" else "project_code" end))))}' \
    <<< "$SPEC_JSON" > "$vars_file"
  terraform -chdir="$dir" apply -input=false -auto-approve -var-file="$vars_file"
  PUBLIC_IP=$(terraform -chdir="$dir" output -raw public_ip)
  SSH_USER=$(terraform -chdir="$dir" output -raw ssh_user)
  INSTANCE_ID=$(terraform -chdir="$dir" output -raw instance_id)
  INSTANCE_TYPE=$(terraform -chdir="$dir" output -raw instance_type)
  export PUBLIC_IP SSH_USER INSTANCE_ID INSTANCE_TYPE
  bash scripts/inventory.sh outputs
  STATUS=frying STAGE=provision STAGE_STATUS=success bash scripts/inventory.sh update
  if [[ "$SOFTWARE" == '[]' ]]; then
    STAGE=software STAGE_STATUS=skipped bash scripts/inventory.sh update
  fi
  if [[ "$AD_JOIN" == false ]]; then
    STAGE=ad-join STAGE_STATUS=skipped bash scripts/inventory.sh update
  fi
  # Downstream Ansible inputs are derived from the committed entity, not dispatch inputs.
  bash scripts/validate.sh existing
else
  terraform -chdir="$dir" destroy -input=false -auto-approve -var "name=$NAME"
  aws s3api delete-object --bucket "$TF_STATE_BUCKET" --key "$key"
  bash scripts/inventory.sh delete
fi
