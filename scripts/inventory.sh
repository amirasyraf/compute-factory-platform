#!/usr/bin/env bash
set -euo pipefail
# All inventory mutations are confined to one VM. Workflow-level concurrency serializes that VM.
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || { echo 'Invalid VM name' >&2; exit 1; }
action=${1:?register, update, outputs, failure or delete}
file="vms/$NAME/catalog-info.yaml"
export NAME
case "$action" in
  register)
    [[ ! -e "vms/$NAME" ]] || { echo 'VM already exists' >&2; exit 1; }
    mkdir -p "vms/$NAME"
    jq -n --arg name "$NAME" --arg team "$TEAM" --arg platform "$PLATFORM" --arg os "$OS" \
      --arg size "$SIZE" --arg software "$SOFTWARE" --argjson ad_join "$AD_JOIN" \
      --arg requested_by "$REQUESTED_BY" --arg requested_at "$(date -u +%FT%TZ)" --arg run_id "$GITHUB_RUN_ID" \
      '{name:$name,team:$team,platform:$platform,os:$os,size:$size,software:($software|if .=="" then [] else split(",") end),ad_join:$ad_join,requested_by:$requested_by,requested_at:$requested_at,run_id:$run_id}' \
      | yq -P '.' > "vms/$NAME/request.yaml"
    jq -n --arg name "$NAME" --arg team "$TEAM" --arg platform "$PLATFORM" --arg os "$OS" \
      --arg size "$SIZE" --arg software "$SOFTWARE" --arg user "$REQUESTED_BY" --arg run "$GITHUB_RUN_ID" \
      --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
      '{apiVersion:"backstage.io/v1alpha1",kind:"Resource",metadata:{name:$name,title:$name,description:("\($os) VM on \($platform) (\($size)) for team \($team)"),annotations:{"cf/status":"provisioning","cf/stages":({provision:"running",baseline:"pending",software:"pending","ad-join":"pending",access:"pending"}|tojson),"cf/platform":$platform,"cf/os":$os,"cf/size":$size,"cf/team":$team,"cf/software":$software,"cf/public-ip":"","cf/ssh-user":"ubuntu","cf/instance-id":"","cf/requested-by":$user,"cf/run-id":$run,"cf/run-url":$url}},spec:{type:"vm",owner:("group:default/"+$team),lifecycle:"poc"}}' \
      | yq -P '.' > "$file"
    ;;
  update)
    [[ -f "$file" ]] || exit 1
    if [[ -n "${STATUS:-}" ]]; then
      export STATUS
      yq -i '.metadata.annotations."cf/status" = strenv(STATUS)' "$file"
    fi
    # A dispatch's STAGE can be inherited by a status-only finalizer.
    if [[ -n "${STAGE_STATUS:-}" ]]; then
      [[ "${STAGE:-}" =~ ^(provision|baseline|software|ad-join|access)$ ]] || exit 1
      [[ "$STAGE_STATUS" =~ ^(pending|running|success|failed|skipped)$ ]] || exit 1
      export STAGE STAGE_STATUS
      stages=$(yq -r '.metadata.annotations."cf/stages"' "$file" | jq -c --arg stage "$STAGE" --arg status "$STAGE_STATUS" '.[$stage]=$status')
      export stages
      yq -i '.metadata.annotations."cf/stages" = strenv(stages)' "$file"
    fi
    ;;
  outputs)
    export PUBLIC_IP SSH_USER INSTANCE_ID
    yq -i '.metadata.annotations."cf/public-ip" = strenv(PUBLIC_IP) | .metadata.annotations."cf/ssh-user" = strenv(SSH_USER) | .metadata.annotations."cf/instance-id" = strenv(INSTANCE_ID)' "$file"
    ;;
  failure)
    # Validation/guard failures must not mutate an existing VM.
    [[ -f "$file" ]] || exit 0
    stages=$(yq -r '.metadata.annotations."cf/stages"' "$file" | jq -c 'with_entries(if .value=="running" then .value="failed" else . end)')
    export stages
    yq -i '.metadata.annotations."cf/status" = "failed" | .metadata.annotations."cf/stages" = strenv(stages)' "$file"
    ;;
  delete) git rm -r -- "vms/$NAME" ;;
  *) echo 'Unknown inventory action' >&2; exit 1 ;;
esac
if [[ "$action" != delete ]]; then
  export GITHUB_RUN_ID
  run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  export run_url
  yq -i '.metadata.annotations."cf/run-id" = strenv(GITHUB_RUN_ID) | .metadata.annotations."cf/run-url" = strenv(run_url)' "$file"
fi

git config user.name 'compute-factory[bot]'
git config user.email 'compute-factory[bot]@users.noreply.github.com'
if [[ "$action" != delete ]]; then
  git add -- "vms/$NAME"
fi
if ! git diff --cached --quiet; then
  git commit -m "vm($NAME): $action ${STAGE:-} ${STAGE_STATUS:-} ${STATUS:-}"
fi
pushed=false
for attempt in 1 2 3 4 5; do
  if git pull --rebase --autostash origin main && git push origin HEAD:main; then
    pushed=true
    break
  fi
  echo "Concurrent inventory push; retry $attempt/5" >&2
done
[[ "$pushed" == true ]] || { echo 'Inventory push failed' >&2; exit 1; }
bash scripts/refresh.sh "resource:default/$NAME"
if [[ "$action" == register || "$action" == delete ]]; then
  bash scripts/refresh.sh 'location:default/cf-vms'
fi
