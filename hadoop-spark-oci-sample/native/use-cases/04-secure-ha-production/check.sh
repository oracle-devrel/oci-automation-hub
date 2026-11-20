#!/usr/bin/env bash
###############################################################################
# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# Use case 04 — Secure HA production. Run this ON the operator VM.
#
# Verifies the secure, highly-available deployment end to end: every node is
# active, the built-in smoke-test Kerberos principal works, and the Spark
# bootstrap tuning is installed. SSH uses the operator's dedicated BDS key.
###############################################################################
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

require_bds_secure_ha

if [ "${BDS_SECURE:-false}" != "true" ] || [ "${BDS_HIGH_AVAILABILITY:-false}" != "true" ]; then
  _red "Use case 04 requires a secure, highly available BDS cluster."
  exit 1
fi

BDS_ID="$(bds_active_cluster_id)"

if [ -z "$BDS_ID" ]; then
  _yel "BDS is enabled but no ACTIVE cluster found. Current clusters:"
  bds_cluster_states
  _yel "If a cluster is still CREATING, wait for ACTIVE and retry."
  exit 1
fi

oci bds instance get --bds-instance-id "$BDS_ID" \
  --query 'data.nodes[].{type:"node-type",ip:"ip-address",state:"lifecycle-state"}' \
  --output table

NODES="$(oci bds instance get --bds-instance-id "$BDS_ID" --query 'data.nodes')"
NON_ACTIVE="$(printf '%s' "$NODES" | jq '[(.data? // .)[] | select(."lifecycle-state" != "ACTIVE")] | length')"
[ "$NON_ACTIVE" -eq 0 ] || { _red "$NON_ACTIVE BDS node(s) are not ACTIVE."; exit 1; }

UTIL_IP="$(bds_node_ip "$BDS_ID" UTILITY)"
MASTER_IP="$(bds_node_ip "$BDS_ID" MASTER)"
[ -n "$UTIL_IP" ] && [ -n "$MASTER_IP" ] || { _red "Could not resolve BDS utility/master IPs."; exit 1; }

configure_bds_ssh || exit 1
SSH_OPTS=("${BDS_SSH_OPTS[@]}")

echo
echo "Verifying Kerberos on the utility node ..."
ssh "${SSH_OPTS[@]}" "opc@$UTIL_IP" 'sudo bash -s' <<'REMOTE_KERBEROS'
set -euo pipefail
KEYTAB=/etc/security/keytabs/smokeuser.headless.keytab
PRINCIPAL=$(klist -kt "$KEYTAB" | awk 'NR>3 {print $4; exit}')
RUN_USER=$(stat -c '%U' "$KEYTAB")
KRB_CACHE="FILE:/tmp/krb5cc_${RUN_USER}_check_$$"
trap 'rm -f "${KRB_CACHE#FILE:}"' EXIT
sudo -u "$RUN_USER" env KRB5CCNAME="$KRB_CACHE" kinit -kt "$KEYTAB" "$PRINCIPAL"
sudo -u "$RUN_USER" env KRB5CCNAME="$KRB_CACHE" klist -s
echo "Kerberos ticket verified for $PRINCIPAL (OS user: $RUN_USER)"
REMOTE_KERBEROS

echo "Verifying bootstrap tuning on a master node ..."
ssh "${SSH_OPTS[@]}" "opc@$MASTER_IP" \
  "sudo grep -q 'stack bootstrap' /etc/spark/conf/spark-defaults.conf 2>/dev/null || sudo grep -q 'stack bootstrap' /etc/spark3/conf/spark-defaults.conf 2>/dev/null" || {
  _red "Bootstrap tuning marker is missing on master $MASTER_IP."
  echo "The bootstrap script must be configured at BDS creation or applied to the live nodes."
  exit 1
}

cat <<EOF

Cluster validation passed: secure + HA, all nodes ACTIVE, Kerberos works, and
the Spark bootstrap tuning is installed.
EOF
