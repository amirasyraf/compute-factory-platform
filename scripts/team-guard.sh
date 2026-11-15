#!/usr/bin/env bash
set -euo pipefail

# Can also be sourced by validation/registration. Normalize catalog refs or bare names.
normalize_team() {
  local value
  value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  value="${value##*/}"
  printf '%s\n' "${value##*:}"
}

team_guard() {
  local wanted candidate
  wanted=$(normalize_team "$1")
  [[ "$wanted" =~ ^[a-z][a-z0-9-]*$ ]] || { echo 'Invalid team' >&2; return 1; }
  local -a teams
  IFS=',' read -r -a teams <<< "${2:-}"
  for candidate in "${teams[@]}"; do
    candidate=$(normalize_team "$candidate")
    if [[ "$candidate" == platform-admins || "$candidate" == "$wanted" ]]; then
      echo "Team guard passed: $wanted"
      return 0
    fi
  done
  echo "Team guard refused: requester is not a member of $wanted" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  team_guard "${TEAM:?}" "${REQUESTER_TEAMS:-}"
fi
