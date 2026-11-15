#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/team-guard.sh
source "$(dirname "$0")/team-guard.sh"
# shellcheck source=scripts/load-spec.sh
source "$(dirname "$0")/load-spec.sh"

[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || { echo 'Invalid VM name' >&2; exit 1; }
mode=${1:?provision or existing}
if [[ "$mode" == provision ]]; then
  [[ ! -e "vms/$NAME" ]] || { echo 'VM name already registered' >&2; exit 1; }
  SPEC_JSON=$(python3 scripts/spec.py <<< "${SPEC_JSON:?}")
  spec_environment
elif [[ "$mode" == existing ]]; then
  load_spec
else
  echo 'Unknown validation mode' >&2; exit 1
fi
team_guard "$TEAM" "${REQUESTER_TEAMS:-}"

if [[ -n "${STAGE:-}" ]]; then
  [[ "$STAGE" =~ ^(baseline|software|ad-join|access)$ ]] || { echo 'Unknown fry stage' >&2; exit 1; }
  if [[ "$STAGE" == software ]]; then
    SPEC_JSON=$(jq --argjson software "${SOFTWARE_INPUT:-[]}" '.configuration.software=$software' <<< "$SPEC_JSON" | python3 scripts/spec.py)
  elif [[ "$STAGE" == ad-join ]]; then
    SPEC_JSON=$(jq '.configuration.adJoin=true' <<< "$SPEC_JSON" | python3 scripts/spec.py)
  fi
  spec_environment
fi

while IFS= read -r package; do
  supported=$(PACKAGE="$package" yq -r '.[strenv(PACKAGE)].linux // ""' ansible/software-catalog.yml)
  [[ -n "$supported" ]] || { echo "Unsupported software for $OS: $package" >&2; exit 1; }
done < <(jq -r '.[]' <<< "$SOFTWARE")

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "team=$TEAM"
    echo "platform=$PLATFORM"
    echo "os=$OS"
    echo "software=$SOFTWARE"
    echo "ad_join=$AD_JOIN"
    echo "spec_json=$SPEC_JSON"
    echo "vars_json=$(jq -cn --arg name "$NAME" --arg team "$TEAM" --arg user "${REQUESTED_BY:?}" \
      --arg platform "$PLATFORM" --arg os "$OS" --argjson software "$SOFTWARE" \
      '{cf_vm_name:$name,cf_team:$team,cf_requested_by:$user,cf_platform:$platform,cf_os:$os,cf_software:$software,cf_ad_domain:"corp.example.local"}')"
    if [[ "$mode" == existing ]]; then
      echo "host=$(yq -r '.metadata.annotations."cf/public-ip"' "vms/$NAME/catalog-info.yaml")"
      echo "ssh_user=$(yq -r '.metadata.annotations."cf/ssh-user"' "vms/$NAME/catalog-info.yaml")"
    fi
  } >> "$GITHUB_OUTPUT"
fi
