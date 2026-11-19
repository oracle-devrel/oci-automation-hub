#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# One-command connect to the OKE operator through the OCI Bastion.
#
# Creates a port-forwarding Bastion session, waits for it to become ACTIVE, and
# drops you into an SSH shell on the operator (via a ProxyCommand jump - no
# local port to manage). The session is deleted automatically on exit.
#
# Usage:
#   scripts/connect-operator.sh                         # reads `terraform output`
#   scripts/connect-operator.sh -b <bastion-ocid> -i <operator-private-ip>
#   scripts/connect-operator.sh ... -k ~/.ssh/id_rsa    # custom key
#   scripts/connect-operator.sh ... -- kubectl -n bigdata get pods   # run a command
#
# Requires: oci CLI, ssh. Your SSH public key (<key>.pub) must be the one you
# passed to the stack as ssh_public_key.
###############################################################################
set -euo pipefail

BASTION_ID="${BASTION_ID:-}"
OPERATOR_IP="${OPERATOR_IP:-}"
KEY="${KEY:-$HOME/.ssh/id_rsa}"
REMOTE_CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--bastion-id)  BASTION_ID="$2"; shift 2 ;;
    -i|--operator-ip) OPERATOR_IP="$2"; shift 2 ;;
    -k|--key)         KEY="$2"; shift 2 ;;
    --)               shift; REMOTE_CMD=("$@"); break ;;
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
done

# Fall back to Terraform outputs when run from the stack directory.
if command -v terraform >/dev/null 2>&1; then
  [ -n "$BASTION_ID" ]  || BASTION_ID="$(terraform output -raw bastion_id 2>/dev/null || true)"
  [ -n "$OPERATOR_IP" ] || OPERATOR_IP="$(terraform output -raw operator_private_ip 2>/dev/null || true)"
fi

[ -n "$BASTION_ID" ]  || { echo "error: bastion OCID not set (-b, \$BASTION_ID, or terraform output bastion_id)" >&2; exit 1; }
[ -n "$OPERATOR_IP" ] || { echo "error: operator IP not set (-i, \$OPERATOR_IP, or terraform output operator_private_ip)" >&2; exit 1; }
[ -f "$KEY" ]         || { echo "error: SSH private key not found: $KEY" >&2; exit 1; }
[ -f "$KEY.pub" ]     || { echo "error: SSH public key not found: $KEY.pub" >&2; exit 1; }
command -v oci >/dev/null 2>&1 || { echo "error: oci CLI not found" >&2; exit 1; }

REGION="$(printf '%s' "$BASTION_ID" | cut -d. -f4)"   # region is embedded in the OCID
BASTION_HOST="host.bastion.${REGION}.oci.oraclecloud.com"

echo ">> creating port-forwarding session to ${OPERATOR_IP}:22 (region ${REGION})"
SID="$(oci bastion session create-port-forwarding \
  --bastion-id "$BASTION_ID" \
  --target-private-ip "$OPERATOR_IP" --target-port 22 \
  --ssh-public-key-file "$KEY.pub" \
  --session-ttl 10800 --display-name "operator-connect" \
  --query 'data.id' --raw-output)"

cleanup() { oci bastion session delete --session-id "$SID" --force >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo ">> waiting for session to become ACTIVE ($SID)"
for _ in $(seq 1 60); do
  st="$(oci bastion session get --session-id "$SID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
  [ "$st" = "ACTIVE" ] && break
  [ "$st" = "FAILED" ] && { echo "error: session entered FAILED state" >&2; exit 1; }
  sleep 5
done
[ "${st:-}" = "ACTIVE" ] || { echo "error: session did not become ACTIVE in time" >&2; exit 1; }

# IdentitiesOnly=yes: use ONLY the -i key, so ssh-agent keys aren't offered
# first and exhaust the bastion's MaxAuthTries (a common publickey failure).
# ServerAlive*: detect a half-open bastion tunnel (idle/TTL-expired) and drop the
# connection instead of letting every tunnelled kubectl hang indefinitely.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
          -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
PROXY="ssh ${SSH_OPTS[*]} -i '$KEY' -W %h:%p -p 22 ${SID}@${BASTION_HOST}"

# A freshly-ACTIVE Bastion session takes a few seconds before its SSH gateway
# accepts the key. Probe (non-interactively) until it does, so the interactive
# connection below doesn't fail on the not-yet-ready window.
echo ">> waiting for the session to accept connections"
for _ in $(seq 1 18); do
  # -n: read stdin from /dev/null so the probe never consumes stdin meant for the
  # final command (lets you pipe a file: connect-operator.sh ... -- 'cat > f' < f).
  if ssh -n "${SSH_OPTS[@]}" -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
       -o ProxyCommand="$PROXY" "opc@${OPERATOR_IP}" true 2>/dev/null; then
    break
  fi
  sleep 5
done

echo ">> connecting to opc@${OPERATOR_IP}"
# ${REMOTE_CMD[@]+...} expands to nothing when empty - safe under `set -u` on
# bash 3.2 (macOS), where a bare "${REMOTE_CMD[@]}" on an empty array errors.
ssh "${SSH_OPTS[@]}" -i "$KEY" -o ProxyCommand="$PROXY" \
  "opc@${OPERATOR_IP}" ${REMOTE_CMD[@]+"${REMOTE_CMD[@]}"}
