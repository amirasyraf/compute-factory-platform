#!/usr/bin/env bash
set -euo pipefail
# Workflow concurrency serializes this VM; unrelated VM commits rebase below.
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || exit 1
action=${1:?register, configure, update, outputs, finalize or delete}
inventory_root=${INVENTORY_ROOT:-.}
file="$inventory_root/vms/$NAME/catalog-info.yaml"
export NAME
if [[ "$action" == register && -f "$file" ]]; then
  [[ "$(yq -r '.metadata.annotations."cf/request-id"' "$file")" == "${REQUEST_ID:?}" ]] || { echo 'VM belongs to a different request' >&2; exit 1; }
  exit 0
fi
if [[ "$action" != register ]]; then
  if [[ ! -f "$file" ]]; then
    [[ "$action" == delete || "$action" == finalize ]] && exit 0
    echo 'Unknown VM' >&2; exit 1
  fi
  if [[ "$(yq -r '.metadata.annotations."cf/request-id"' "$file")" != "${REQUEST_ID:?}" ]]; then
    [[ "$action" == finalize ]] && exit 0
    echo 'VM belongs to a different request' >&2; exit 1
  fi
fi
case "$action" in
  register)
    [[ ! -e "$inventory_root/vms/$NAME" ]] || { echo 'VM directory already exists' >&2; exit 1; }
    SPEC_JSON=$(python3 scripts/spec.py <<< "${SPEC_JSON:?}")
    # shellcheck source=scripts/load-spec.sh
    source "$(dirname "$0")/load-spec.sh"
    spec_environment
    mkdir -p "$inventory_root/vms/$NAME"
    jq -n --arg name "$NAME" --arg team "$TEAM" --arg platform "$PLATFORM" --arg os "$OS" \
      --arg size "$SIZE" --arg user "${REQUESTED_BY:?}" --arg request "${REQUEST_ID:?}" \
      --arg requested_at "$(date -u +%FT%TZ)" --argjson spec "$SPEC_JSON" \
      '{apiVersion:"backstage.io/v1alpha1",kind:"Resource",metadata:{name:$name,title:$name,description:("\($os) VM on \($platform) (\($size)) for team \($team)"),annotations:{"cf/status":"provisioning","cf/public-ip":"","cf/ssh-user":"ubuntu","cf/instance-id":"","cf/instance-type":"","cf/requested-by":$user,"cf/requested-at":$requested_at,"cf/request-id":$request}},spec:$spec}' \
      | yq -P '.' > "$file"
    ;;
  configure)
    configuration=$(python3 scripts/spec.py <<< "${SPEC_JSON:?}" | jq -c '.configuration')
    export configuration
    yq -i '.spec.configuration = (strenv(configuration) | from_json)' "$file"
    ;;
  update)
    [[ "${STATUS:?}" =~ ^(provisioning|frying|destroying)$ ]] || exit 1
    export STATUS
    yq -i '.metadata.annotations."cf/status" = strenv(STATUS)' "$file"
    ;;
  outputs)
    export PUBLIC_IP SSH_USER INSTANCE_ID INSTANCE_TYPE
    yq -i '.metadata.annotations."cf/public-ip" = strenv(PUBLIC_IP) | .metadata.annotations."cf/ssh-user" = strenv(SSH_USER) | .metadata.annotations."cf/instance-id" = strenv(INSTANCE_ID) | .metadata.annotations."cf/instance-type" = strenv(INSTANCE_TYPE)' "$file"
    ;;
  finalize)
    [[ "${OUTCOME:?}" == ready || "$OUTCOME" == failed ]] || exit 1
    timestamp=$(date -u +%FT%TZ)
    timestamp_key="cf/$OUTCOME-at"
    export OUTCOME timestamp timestamp_key
    yq -i '.metadata.annotations."cf/status" = strenv(OUTCOME) | .metadata.annotations[strenv(timestamp_key)] = (.metadata.annotations[strenv(timestamp_key)] // strenv(timestamp))' "$file"
    ;;
  delete) git -C "$inventory_root" rm -r -- "vms/$NAME" ;;
  *) echo 'Unknown inventory action' >&2; exit 1 ;;
esac
if [[ "$action" != delete ]]; then
  export GITHUB_RUN_ID
  run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  export run_url
  yq -i '.metadata.annotations."cf/run-id" = strenv(GITHUB_RUN_ID) | .metadata.annotations."cf/run-url" = strenv(run_url)' "$file"
fi
git -C "$inventory_root" config user.name 'compute-factory[bot]'
git -C "$inventory_root" config user.email 'compute-factory[bot]@users.noreply.github.com'
if [[ "$action" != delete ]]; then git -C "$inventory_root" add -- "vms/$NAME"; fi
if ! git -C "$inventory_root" diff --cached --quiet; then git -C "$inventory_root" commit -m "vm($NAME): $action ${STATUS:-} ${OUTCOME:-}"; fi
pushed=false
for attempt in 1 2 3 4 5 6 7 8; do
  if git -C "$inventory_root" pull --rebase --autostash origin main && git -C "$inventory_root" push origin HEAD:main; then
    pushed=true
    break
  fi
  echo "Concurrent inventory push; retry $attempt/8" >&2
  sleep $((attempt + RANDOM % (attempt * 2 + 1)))
done
[[ "$pushed" == true ]] || { echo 'Inventory push failed' >&2; exit 1; }
bash scripts/refresh.sh "resource:default/$NAME"
if [[ "$action" == register || "$action" == delete ]]; then bash scripts/refresh.sh 'location:default/cf-vms'; fi
