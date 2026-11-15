#!/usr/bin/env bash
set -euo pipefail
action=${1:?apply or destroy}
[[ "$action" == apply || "$action" == destroy ]] || exit 1
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ && "${PLATFORM:?}" == aws ]] || exit 1
dir="terraform/platforms/$PLATFORM"
key="vms/$PLATFORM/$NAME/terraform.tfstate"
if [[ "$action" == apply ]]; then
  STATUS=provisioning STAGE=provision STAGE_STATUS=running bash scripts/inventory.sh update
fi
terraform -chdir="$dir" init -input=false -lockfile=readonly \
  -backend-config="bucket=${TF_STATE_BUCKET:?}" -backend-config="key=$key" \
  -backend-config="region=${AWS_REGION:?}" -backend-config=use_lockfile=true
if [[ "$action" == apply ]]; then
  terraform -chdir="$dir" apply -input=false -auto-approve \
    -var "name=$NAME" -var "os=$OS" -var "size=$SIZE" -var "team=$TEAM" -var "requested_by=$REQUESTED_BY"
  PUBLIC_IP=$(terraform -chdir="$dir" output -raw public_ip)
  SSH_USER=$(terraform -chdir="$dir" output -raw ssh_user)
  INSTANCE_ID=$(terraform -chdir="$dir" output -raw instance_id)
  export PUBLIC_IP SSH_USER INSTANCE_ID
  {
    echo "host=$PUBLIC_IP"
    echo "ssh_user=$SSH_USER"
  } >> "$GITHUB_OUTPUT"
  bash scripts/inventory.sh outputs
  STATUS=frying STAGE=provision STAGE_STATUS=success bash scripts/inventory.sh update
  if [[ -z "$SOFTWARE" ]]; then
    STAGE=software STAGE_STATUS=skipped bash scripts/inventory.sh update
  fi
  if [[ "$AD_JOIN" == false ]]; then
    STAGE=ad-join STAGE_STATUS=skipped bash scripts/inventory.sh update
  fi
else
  terraform -chdir="$dir" destroy -input=false -auto-approve -var "name=$NAME"
  aws s3api delete-object --bucket "$TF_STATE_BUCKET" --key "$key"
  bash scripts/inventory.sh delete
fi
