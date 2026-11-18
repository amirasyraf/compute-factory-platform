#!/usr/bin/env bash
set -euo pipefail
host=${1:?host}
user=${2:?ssh user}
key=${3:?key}
# Let OpenSSH handle connection retries; the whole command has a hard deadline.
# `exit` works in every login shell (sh, PowerShell, cmd); `true` is not a Windows command.
timeout 310 ssh -i "$key" -o "CertificateFile=$key-cert.pub" \
  -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=60 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$host" exit
