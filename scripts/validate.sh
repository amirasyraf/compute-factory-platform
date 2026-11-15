#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/team-guard.sh
source "$(dirname "$0")/team-guard.sh"

[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || { echo 'Invalid VM name' >&2; exit 1; }
mode=${1:?provision or existing}
if [[ "$mode" == provision ]]; then
  [[ ! -e "vms/$NAME" ]] || { echo 'VM name already registered' >&2; exit 1; }
  [[ "$PLATFORM" == aws && "$OS" == ubuntu ]] || { echo 'Unsupported platform/OS' >&2; exit 1; }
  [[ "$SIZE" =~ ^[SML]$ ]] || { echo 'Invalid size' >&2; exit 1; }
  [[ "$AD_JOIN" == true || "$AD_JOIN" == false ]] || { echo 'Invalid ad_join' >&2; exit 1; }
  TEAM=$(normalize_team "$TEAM")
else
  [[ -f "vms/$NAME/request.yaml" ]] || { echo 'Unknown VM' >&2; exit 1; }
  TEAM=$(yq -r '.team' "vms/$NAME/request.yaml")
  PLATFORM=$(yq -r '.platform' "vms/$NAME/request.yaml")
  OS=$(yq -r '.os' "vms/$NAME/request.yaml")
  [[ "$PLATFORM" == aws && "$OS" == ubuntu ]] || { echo 'Unsupported platform/OS' >&2; exit 1; }
  if [[ -n "${STAGE:-}" ]]; then
    [[ "$STAGE" =~ ^(baseline|software|ad-join|access)$ ]] || { echo 'Unknown fry stage' >&2; exit 1; }
  fi
fi
team_guard "$TEAM" "${REQUESTER_TEAMS:-}"

software_json=$(jq -cn --arg value "${SOFTWARE:-}" '$value | if . == "" then [] else split(",") end')
while IFS= read -r package; do
  # OS family mapping intentionally lives at this boundary for future OSes.
  supported=$(PACKAGE="$package" yq -r '.[strenv(PACKAGE)].linux // ""' ansible/software-catalog.yml)
  [[ -n "$supported" ]] || { echo "Unsupported software for $OS: $package" >&2; exit 1; }
done < <(jq -r '.[]' <<< "$software_json")

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "team=$TEAM"
    echo "platform=$PLATFORM"
    echo "os=$OS"
    echo "vars_json=$(jq -cn --arg name "$NAME" --arg team "$TEAM" --arg user "$REQUESTED_BY" \
      --arg platform "$PLATFORM" --arg os "$OS" --argjson software "$software_json" \
      '{cf_vm_name:$name,cf_team:$team,cf_requested_by:$user,cf_platform:$platform,cf_os:$os,cf_software:$software,cf_ad_domain:"corp.example.local"}')"
    if [[ "$mode" != provision ]]; then
      echo "host=$(yq -r '.metadata.annotations."cf/public-ip"' "vms/$NAME/catalog-info.yaml")"
      echo "ssh_user=$(yq -r '.metadata.annotations."cf/ssh-user"' "vms/$NAME/catalog-info.yaml")"
    fi
  } >> "$GITHUB_OUTPUT"
fi
