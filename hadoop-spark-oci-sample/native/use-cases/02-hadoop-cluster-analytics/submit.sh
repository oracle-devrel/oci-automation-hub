#!/usr/bin/env bash
###############################################################################
# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# Use case 02 — Hadoop cluster analytics. Run this ON the operator VM.
#
# spark-submit has to run ON a BDS node. This script runs on the operator, uses
# its deployment-managed BDS key, resolves the target, copies the job, acquires
# Kerberos credentials when needed, submits it, and verifies the HDFS output.
###############################################################################
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

require_bds

echo "Resolving the BDS cluster in compartment $COMPARTMENT_OCID ..."
BDS_ID="$(bds_active_cluster_id)"

if [ -z "$BDS_ID" ]; then
  _yel "BDS is enabled but no ACTIVE cluster was found. Current clusters:"
  bds_cluster_states
  _yel "If a cluster is still CREATING, wait for it to reach ACTIVE and retry."
  exit 1
fi

UTIL_IP="$(bds_node_ip "$BDS_ID" UTILITY)"
MASTER_IP="$(bds_node_ip "$BDS_ID" MASTER)"

_grn "Cluster:      $BDS_ID"
_grn "Utility node: ${UTIL_IP:-<unknown>}"
_grn "Master node:  ${MASTER_IP:-<unknown>}"

TARGET_IP="${UTIL_IP:-$MASTER_IP}"

configure_bds_ssh || exit 1
SSH_OPTS=("${BDS_SSH_OPTS[@]}")

echo "Copying the Spark job and sample data to opc@$TARGET_IP:/tmp/"
scp "${SSH_OPTS[@]}" "$HERE/sales_report.py" "$HERE/sales.csv" "opc@$TARGET_IP:/tmp/"

if [ "${BDS_SECURE:-false}" = "true" ]; then
  echo "Secure cluster detected; submitting as the BDS smoke-test user."
  ssh "${SSH_OPTS[@]}" "opc@$TARGET_IP" 'sudo bash -s' <<'REMOTE_SECURE'
set -euo pipefail

KEYTAB=/etc/security/keytabs/smokeuser.headless.keytab
[ -r "$KEYTAB" ] || { echo "BDS smoke-user keytab not found: $KEYTAB" >&2; exit 1; }
PRINCIPAL=$(klist -kt "$KEYTAB" | awk 'NR>3 {print $4; exit}')
[ -n "$PRINCIPAL" ] || { echo "No principal found in $KEYTAB" >&2; exit 1; }
RUN_USER=$(stat -c '%U' "$KEYTAB")
[ -n "$RUN_USER" ] || { echo "Could not resolve the smoke-test OS user" >&2; exit 1; }

KRB_CACHE="FILE:/tmp/krb5cc_${RUN_USER}_usecase_$$"
trap 'rm -f "${KRB_CACHE#FILE:}"' EXIT
sudo -u "$RUN_USER" env KRB5CCNAME="$KRB_CACHE" kinit -kt "$KEYTAB" "$PRINCIPAL"
sudo -u "$RUN_USER" env KRB5CCNAME="$KRB_CACHE" klist

HDFS_HOME="/user/$RUN_USER"
sudo -u "$RUN_USER" env KRB5CCNAME="$KRB_CACHE" hdfs dfs -mkdir -p "$HDFS_HOME/sales"
sudo -u "$RUN_USER" env KRB5CCNAME="$KRB_CACHE" hdfs dfs -put -f /tmp/sales.csv "$HDFS_HOME/sales/"
sudo -u "$RUN_USER" env KRB5CCNAME="$KRB_CACHE" spark-submit \
  --master yarn --deploy-mode cluster \
  --num-executors 3 --executor-cores 4 --executor-memory 8g \
  /tmp/sales_report.py \
  "hdfs://$HDFS_HOME/sales/sales.csv" "hdfs://$HDFS_HOME/sales_report"

echo "Verified HDFS report:"
sudo -u "$RUN_USER" env KRB5CCNAME="$KRB_CACHE" \
  hdfs dfs -cat "$HDFS_HOME/sales_report/part-*.csv"
REMOTE_SECURE
else
  echo "Non-secure cluster detected; submitting as opc."
  ssh "${SSH_OPTS[@]}" "opc@$TARGET_IP" 'bash -s' <<'REMOTE_NONSECURE'
set -euo pipefail
hdfs dfs -mkdir -p /user/opc/sales
hdfs dfs -put -f /tmp/sales.csv /user/opc/sales/
spark-submit --master yarn --deploy-mode cluster \
  --num-executors 3 --executor-cores 4 --executor-memory 8g \
  /tmp/sales_report.py \
  hdfs:///user/opc/sales/sales.csv hdfs:///user/opc/sales_report

echo "Verified HDFS report:"
hdfs dfs -cat '/user/opc/sales_report/part-*.csv'
REMOTE_NONSECURE
fi

_grn "BDS Spark job completed and its HDFS output was verified."
