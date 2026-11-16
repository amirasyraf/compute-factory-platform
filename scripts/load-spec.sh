#!/usr/bin/env bash
# Source after validating NAME. Only persisted spec is used for existing VMs.
load_spec() {
  local file="vms/$NAME/catalog-info.yaml"
  [[ -f "$file" ]] || { echo 'Unknown VM' >&2; return 1; }
  [[ "$(yq -r '.kind' "$file")" == Resource && "$(yq -r '.metadata.name' "$file")" == "$NAME" ]] \
    || { echo 'VM entity identity mismatch' >&2; return 1; }
  SPEC_JSON=$(yq -o=json '.spec' "$file" | python3 scripts/spec.py) || return 1
  spec_environment
}

spec_environment() {
  TEAM=$(jq -r '.owner | split("/")[-1]' <<< "$SPEC_JSON")
  PLATFORM=$(jq -r '.compute.platform' <<< "$SPEC_JSON")
  OS=$(jq -r '.compute.os' <<< "$SPEC_JSON")
  # A size letter, or the explicit instance type chosen in the advanced picker.
  SIZE=$(jq -r '.compute.size // .compute.instanceType' <<< "$SPEC_JSON")
  SOFTWARE=$(jq -c '.configuration.software' <<< "$SPEC_JSON")
  AD_JOIN=$(jq -r '.configuration.adJoin' <<< "$SPEC_JSON")
  export SPEC_JSON TEAM PLATFORM OS SIZE SOFTWARE AD_JOIN
}
