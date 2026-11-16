#!/usr/bin/env bash
set -euo pipefail
# All inventory mutations are confined to one VM. Workflow-level concurrency serializes that VM.
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || { echo 'Invalid VM name' >&2; exit 1; }
action=${1:?register, configure, update, outputs, failure or delete}
file="vms/$NAME/catalog-info.yaml"
export NAME
case "$action" in
  register)
    [[ ! -e "vms/$NAME" ]] || { echo 'VM already exists' >&2; exit 1; }
    SPEC_JSON=$(python3 scripts/spec.py <<< "${SPEC_JSON:?}")
    # shellcheck source=scripts/load-spec.sh
    source "$(dirname "$0")/load-spec.sh"
    spec_environment
    mkdir -p "vms/$NAME"
    jq -n --arg name "$NAME" --arg team "$TEAM" --arg platform "$PLATFORM" --arg os "$OS" \
      --arg size "$SIZE" --arg user "$REQUESTED_BY" --arg run "$GITHUB_RUN_ID" \
      --arg requested_at "$(date -u +%FT%TZ)" --argjson spec "$SPEC_JSON" \
      --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
      '{apiVersion:"backstage.io/v1alpha1",kind:"Resource",metadata:{name:$name,title:$name,description:("\($os) VM on \($platform) (\($size)) for team \($team)"),annotations:{"cf/status":"provisioning","cf/stages":({provision:"pending",baseline:"pending",software:"pending","ad-join":"pending",access:"pending"}|tojson),"cf/processes":({validate:"success",register:"success",provision:"pending","fry-baseline":"pending","fry-software":"pending","fry-ad-join":"pending","fry-access":"pending",finalize:"pending","on-failure":"pending"}|tojson),"cf/public-ip":"","cf/ssh-user":"ubuntu","cf/instance-id":"","cf/instance-type":"","cf/requested-by":$user,"cf/requested-at":$requested_at,"cf/run-id":$run,"cf/run-url":$url}},spec:$spec}' \
      | yq -P '.' > "$file"
    export REQUEST_ID="${REQUEST_ID:-manual:$GITHUB_RUN_ID}"
    yq -i '.metadata.annotations."cf/request-id" = strenv(REQUEST_ID) | .metadata.annotations."cf/provision-run-id" = strenv(GITHUB_RUN_ID)' "$file"
    ;;
  configure)
    [[ -f "$file" ]] || exit 1
    configuration=$(python3 scripts/spec.py <<< "${SPEC_JSON:?}" | jq -c '.configuration')
    export configuration
    yq -i '.spec.configuration = (strenv(configuration) | from_json)' "$file"
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
      process="$STAGE"
      case "$STAGE" in
        baseline) process=fry-baseline ;;
        software) process=fry-software ;;
        ad-join) process=fry-ad-join ;;
        access) process=fry-access ;;
      esac
      export process
      processes=$(yq -r '.metadata.annotations."cf/processes" // "{}"' "$file" | jq -c --arg process "$process" --arg status "$STAGE_STATUS" '.[$process]=$status')
      export processes
      yq -i '.metadata.annotations."cf/processes" = strenv(processes)' "$file"
    fi
    if [[ -n "${PROCESS:-}" || -n "${PROCESS_STATUS:-}" ]]; then
      [[ "${PROCESS:-}" =~ ^(validate|register|provision|fry-baseline|fry-software|fry-ad-join|fry-access|finalize|on-failure)$ ]] || exit 1
      [[ "${PROCESS_STATUS:-}" =~ ^(pending|running|success|failed|skipped)$ ]] || exit 1
      export PROCESS PROCESS_STATUS
      processes=$(yq -r '.metadata.annotations."cf/processes" // "{}"' "$file" | jq -c --arg process "$PROCESS" --arg status "$PROCESS_STATUS" '.[$process]=$status')
      export processes
      yq -i '.metadata.annotations."cf/processes" = strenv(processes)' "$file"
    fi
    if [[ "${STATUS:-}" == ready ]]; then
      READY_AT="$(date -u +%FT%TZ)"
      export READY_AT
      yq -i '.metadata.annotations."cf/ready-at" = (.metadata.annotations."cf/ready-at" // strenv(READY_AT))' "$file"
      processes=$(yq -r '.metadata.annotations."cf/processes" // "{}"' "$file" | jq -c '.finalize="success" | ."on-failure"="skipped"')
      export processes
      yq -i '.metadata.annotations."cf/processes" = strenv(processes)' "$file"
    fi
    ;;
  outputs)
    export PUBLIC_IP SSH_USER INSTANCE_ID INSTANCE_TYPE
    yq -i '.metadata.annotations."cf/public-ip" = strenv(PUBLIC_IP) | .metadata.annotations."cf/ssh-user" = strenv(SSH_USER) | .metadata.annotations."cf/instance-id" = strenv(INSTANCE_ID) | .metadata.annotations."cf/instance-type" = strenv(INSTANCE_TYPE)' "$file"
    ;;
  failure)
    # Validation/guard failures must not mutate an existing VM.
    [[ -f "$file" ]] || exit 0
    FAILED_AT="$(date -u +%FT%TZ)"
    export FAILED_AT
    yq -i '.metadata.annotations."cf/failed-at" = (.metadata.annotations."cf/failed-at" // strenv(FAILED_AT))' "$file"
    stages=$(yq -r '.metadata.annotations."cf/stages"' "$file" | jq -c 'with_entries(if .value=="running" then .value="failed" else . end)')
    export stages
    yq -i '.metadata.annotations."cf/status" = "failed" | .metadata.annotations."cf/stages" = strenv(stages)' "$file"
    processes=$(yq -r '.metadata.annotations."cf/processes" // "{}"' "$file" | jq -c 'with_entries(if .value=="running" then .value="failed" else . end) | ."on-failure"="success"')
    export processes
    yq -i '.metadata.annotations."cf/processes" = strenv(processes)' "$file"
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
for attempt in 1 2 3 4 5 6 7 8; do
  if git pull --rebase --autostash origin main && git push origin HEAD:main; then
    pushed=true
    break
  fi
  echo "Concurrent inventory push; retry $attempt/8" >&2
  # Jittered backoff so concurrent VM runs stop colliding on the same push.
  sleep $((attempt + RANDOM % (attempt * 2 + 1)))
done
[[ "$pushed" == true ]] || { echo 'Inventory push failed' >&2; exit 1; }
bash scripts/refresh.sh "resource:default/$NAME"
if [[ "$action" == register || "$action" == delete ]]; then
  bash scripts/refresh.sh 'location:default/cf-vms'
fi
