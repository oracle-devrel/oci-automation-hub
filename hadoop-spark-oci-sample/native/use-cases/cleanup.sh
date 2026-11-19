#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Pre-destroy cleanup. Run this ON the operator (instance-principal auth) before
# `terraform destroy` to remove the runtime state that would otherwise block the
# teardown:
#   * stops the Data Flow warm pool (a running pool can't be deleted)
#   * empties the scripts / logs / warehouse buckets (a non-empty bucket can't
#     be deleted)
#
# The Terraform stack also attempts this automatically via destroy-time hooks
# (cleanup.tf), but those depend on the destroy host having OCI CLI auth — this
# script is the reliable fallback because the operator always has instance
# principal.
###############################################################################
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$HERE/lib.sh"   # loads deployment.env + OCI_CLI_AUTH=instance_principal

require_deployment_env

# 1. Stop the warm pool, if there is one.
if [ -n "${DATAFLOW_POOL_ID:-}" ]; then
  echo "Stopping Data Flow pool $DATAFLOW_POOL_ID ..."
  oci data-flow pool stop --pool-id "$DATAFLOW_POOL_ID" --wait-for-state SUCCEEDED || \
    _yel "Pool stop did not complete cleanly — check the console before destroying."
else
  echo "No warm pool to stop."
fi

# 2. Empty the buckets.
for b in "${SCRIPTS_BUCKET:-}" "${LOGS_BUCKET:-}" "${WAREHOUSE_BUCKET:-}"; do
  [ -n "$b" ] || continue
  echo "Emptying bucket $b ..."
  oci os object bulk-delete -bn "$b" --namespace "$OS_NAMESPACE" --force || \
    _yel "Could not fully empty $b — check for in-progress multipart uploads."
done

_grn "Cleanup complete. You can now run terraform destroy."
