#!/usr/bin/env bash
set -euo pipefail
# Pure validation: no network, inventory writes, or infrastructure operations here.
# shellcheck source=scripts/team-guard.sh
source "$(dirname "$0")/team-guard.sh"
# shellcheck source=scripts/load-spec.sh
source "$(dirname "$0")/load-spec.sh"
fail() { echo "$*" >&2; exit 1; }
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || fail 'Invalid VM name'
[[ "${STAGE:?}" =~ ^(register|provision|baseline|software|ad-join|access|configure|start|stop|reboot|os-update|destroy|finalize)$ ]] || fail 'Invalid stage'
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
  configure) jq -e 'keys == ["compute","configuration"] and (.compute|type=="object") and (.configuration|type=="object")' <<< "$params" >/dev/null ;;
  software) jq -e '. == {} or (keys == ["remove"] and (.remove|type=="array" and length <= 20 and all(type=="string")))' <<< "$params" >/dev/null ;;
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
      # Modify replaces compute and configuration; platform, OS and every other section are kept.
      jq -e --argjson change "$params" '.compute.platform == $change.compute.platform and .compute.os == $change.compute.os' <<< "$SPEC_JSON" >/dev/null \
        || fail 'Modify cannot change the platform or OS'
      SPEC_JSON=$(jq --argjson change "$params" '.compute = $change.compute | .configuration = $change.configuration' <<< "$SPEC_JSON" | python3 scripts/spec.py)
      spec_environment
    fi
  fi
fi
if [[ "$noop" == false ]]; then
  platform_file="terraform/platforms/$PLATFORM/platform.json"
  FAMILY=$(jq -r --arg os "$OS" '.os[$os].family' "$platform_file")
  SSH_USER=$(jq -r --arg os "$OS" '.os[$os].sshUser' "$platform_file")
  export FAMILY
  # Packages deselected by Modify; anything still desired is never removed.
  REMOVE=$(jq -c --argjson keep "$SOFTWARE" '(.remove // []) - $keep | unique' <<< "$params")
  while IFS= read -r package; do
    supported=$(PACKAGE="$package" yq -r '.[strenv(PACKAGE)][strenv(FAMILY)] // ""' ansible/software-catalog.yml)
    [[ -n "$supported" ]] || fail "Unsupported software for $OS: $package"
  done < <(jq -r '.[]' <<< "$SOFTWARE" && jq -r '.[]' <<< "$REMOVE")
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "noop=$noop"
    echo "demo_generation=$(jq -r '.demoGeneration // ""' <<< "$params")"
    echo "outcome=$(jq -r '.outcome // ""' <<< "$params")"
    if [[ "$noop" == false ]]; then
      echo "platform=$PLATFORM"
      echo "spec_json=$SPEC_JSON"
      user=$REQUESTED_BY
      if [[ "$STAGE" != register ]]; then user=$(yq -r '.metadata.annotations."cf/requested-by"' "$file"); fi
      echo "vars_json=$(jq -cn --arg name "$NAME" --arg team "$TEAM" --arg user "$user" \
        --arg platform "$PLATFORM" --arg os "$OS" --argjson software "$SOFTWARE" --argjson remove "$REMOVE" \
        --argjson ad_join "$AD_JOIN" \
        '{cf_vm_name:$name,cf_team:$team,cf_requested_by:$user,cf_platform:$platform,cf_os:$os,cf_software:$software,cf_software_remove:$remove,cf_ad_join:$ad_join,cf_ad_domain:"corp.example.local"}')"
      if [[ "$STAGE" =~ ^(baseline|software|ad-join|access|reboot|os-update)$ ]]; then
        host=$(yq -r '.metadata.annotations."cf/public-ip"' "$file")
        ssh_user=$(yq -r '.metadata.annotations."cf/ssh-user"' "$file")
        [[ -n "$host" ]] || fail 'The VM has no public IP; start it first'
        [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ssh_user" == "$SSH_USER" ]] || fail 'Invalid SSH target'
        echo "host=$host"
      fi
      if [[ "$STAGE" =~ ^(start|stop|reboot)$ ]]; then
        instance=$(yq -r '.metadata.annotations."cf/instance-id"' "$file")
        [[ "$instance" =~ $(jq -r '.instanceIdPattern' "$platform_file") ]] || fail 'The VM has no recorded instance'
        echo "instance_id=$instance"
      fi
      echo "ssh_user=$SSH_USER"
    fi
  } >> "$GITHUB_OUTPUT"
fi
