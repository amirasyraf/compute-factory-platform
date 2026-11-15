#!/usr/bin/env bash
set -euo pipefail
umask 077
key=${1:?ephemeral key path}
ca=$(mktemp)
trap 'rm -f "$ca"' EXIT
ssh-keygen -q -t ed25519 -N '' -f "$key"
aws secretsmanager get-secret-value --secret-id compute-factory/ssh-ca --query SecretString --output text > "$ca"
ssh-keygen -s "$ca" -I "gha-${GITHUB_RUN_ID:?}" -n cf-automation -V -1m:+1h "${key}.pub"
# The EXIT trap also handles fetch/sign failures. The CA is not kept during Ansible.
