#!/usr/bin/env bash
set -euo pipefail
# Pure validation: no network, inventory writes, or infrastructure operations here.
# shellcheck source=scripts/team-guard.sh
source "$(dirname "$0")/team-guard.sh"
# shellcheck source=scripts/load-spec.sh
source "$(dirname "$0")/load-spec.sh"
fail() { echo "$*" >&2; exit 1; }
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || fail 'Invalid VM name'
[[ "${STAGE:?}" =~ ^(register|provision|baseline|software|ad-join|access|configure|destroy|finalize)$ ]] || fail 'Invalid stage'
[[ "${REQUEST_ID:?}" =~ ^[a-zA-Z0-9_-]{1,100}$ ]] || fail 'Invalid request ID'
[[ "${RUN_KEY:?}" =~ ^[1-9][0-9]*\.$STAGE\.[1-9][0-9]*$ ]] || fail 'Invalid run key'
[[ "${REQUESTED_BY:?}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}$ ]] || fail 'Invalid requester'
[[ "${REQUESTER_TEAMS:?}" =~ ^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)*$ ]] || fail 'Invalid requester teams'
params=${PARAMS_JSON:-}
if [[ -z "$params" ]]; then params='{}'; fi
[[ $(printf %s "$params" | wc -c) -le 40960 ]] || fail 'params_json exceeds 40 KiB'
jq -se 'length == 1 and (.[0] | type == "object")' <<< "$params" >/dev/null || fail 'params_json must be one object'
case "$STAGE" in
  register) jq -e 'keys == ["spec"] and (.spec|type=="object")' <<< "$params" >/dev/null ;;
  configure) jq -e '(keys == ["software"] and (.software|type=="array")) or (keys == ["adJoin"] and .adJoin == true)' <<< "$params" >/dev/null ;;
  destroy) jq -e '. == {} or (keys == ["demoGeneration"] and (.demoGeneration|type=="string" and test("^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$")))' <<< "$params" >/dev/null ;;
  finalize) jq -e 'keys == ["outcome"] and (.outcome == "ready" or .outcome == "failed")' <<< "$params" >/dev/null ;;
  *) jq -e '. == {}' <<< "$params" >/dev/null ;;
esac
file="${INVENTORY_ROOT:-.}/vms/$NAME/catalog-info.yaml"
noop=false
if [[ "$STAGE" == register ]]; then
  SPEC_JSON=$(jq -c '.spec' <<< "$params" | python3 scripts/spec.py)
  spec_environment
  team_guard "$TEAM" "$REQUESTER_TEAMS"
  if [[ -f "$file" ]]; then
    [[ "$(yq -r '.metadata.annotations."cf/request-id"' "$file")" == "$REQUEST_ID" ]] || fail 'VM belongs to a different request'
    load_spec
    team_guard "$TEAM" "$REQUESTER_TEAMS"
    noop=true
  else
    [[ ! -e "${INVENTORY_ROOT:-.}/vms/$NAME" ]] || fail 'VM directory exists without inventory'
  fi
elif [[ ! -f "$file" ]]; then
  [[ "$STAGE" == destroy || "$STAGE" == finalize ]] || fail 'Unknown VM'
  noop=true
else
  current=$(yq -r '.metadata.annotations."cf/request-id"' "$file")
  if [[ "$current" != "$REQUEST_ID" ]]; then
    if [[ "$STAGE" == finalize || ( "$STAGE" == destroy && "$(jq -r 'has("demoGeneration")' <<< "$params")" == true ) ]]; then
      noop=true
    else
      fail 'VM belongs to a different request'
    fi
  fi
  if [[ "$noop" == false ]]; then
    load_spec
    team_guard "$TEAM" "$REQUESTER_TEAMS"
    if [[ "$STAGE" == configure ]]; then
      if jq -e 'has("software")' <<< "$params" >/dev/null; then
        SPEC_JSON=$(jq --argjson change "$params" '.configuration.software += ($change.software - .configuration.software)' <<< "$SPEC_JSON" | python3 scripts/spec.py)
      else
        SPEC_JSON=$(jq '.configuration.adJoin=true' <<< "$SPEC_JSON" | python3 scripts/spec.py)
      fi
      spec_environment
    fi
  fi
fi
if [[ "$noop" == false ]]; then
  while IFS= read -r package; do
    supported=$(PACKAGE="$package" yq -r '.[strenv(PACKAGE)].linux // ""' ansible/software-catalog.yml)
    [[ -n "$supported" ]] || fail "Unsupported software for $OS: $package"
  done < <(jq -r '.[]' <<< "$SOFTWARE")
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "noop=$noop"
    echo "demo_generation=$(jq -r '.demoGeneration // ""' <<< "$params")"
    echo "outcome=$(jq -r '.outcome // ""' <<< "$params")"
    if [[ "$noop" == false ]]; then
      echo "spec_json=$SPEC_JSON"
      user=$REQUESTED_BY
      if [[ "$STAGE" != register ]]; then user=$(yq -r '.metadata.annotations."cf/requested-by"' "$file"); fi
      echo "vars_json=$(jq -cn --arg name "$NAME" --arg team "$TEAM" --arg user "$user" \
        --arg platform "$PLATFORM" --arg os "$OS" --argjson software "$SOFTWARE" \
        '{cf_vm_name:$name,cf_team:$team,cf_requested_by:$user,cf_platform:$platform,cf_os:$os,cf_software:$software,cf_ad_domain:"corp.example.local"}')"
      if [[ "$STAGE" =~ ^(baseline|software|ad-join|access)$ ]]; then
        host=$(yq -r '.metadata.annotations."cf/public-ip"' "$file")
        ssh_user=$(yq -r '.metadata.annotations."cf/ssh-user"' "$file")
        [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ssh_user" == ubuntu ]] || fail 'Invalid SSH target'
        echo "host=$host"
        echo "ssh_user=$ssh_user"
      fi
    fi
  } >> "$GITHUB_OUTPUT"
fi
