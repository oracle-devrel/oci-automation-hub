#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Use case 03 — Low-latency repeated jobs. Run this ON the operator VM.
#
# Self-checks Data Flow (and warns if no warm pool), stages the job + seed
# data, ensures a Data Flow application (attached to the warm pool if present),
# and submits a run. Submit it a few times to feel the warm-pool fast starts.
###############################################################################
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

require_dataflow
require_scripts_bucket
require_warehouse_bucket
require_warm_pool   # warn-only

put_script "$HERE/hourly_aggregate.py" "hourly_aggregate.py"
put_script "$HERE/events.csv" "events.csv"

APP_NAME="${RESOURCE_PREFIX}-hourly-aggregate"
FILE_URI="$(os_uri hourly_aggregate.py "$SCRIPTS_BUCKET")"
APP_ID="$(ensure_dataflow_app "$APP_NAME" PYTHON 3.5.0 "$FILE_URI" 2 1 16 2 16)"
_grn "Application: $APP_NAME ($APP_ID)"

INPUT="$(os_uri events.csv "$SCRIPTS_BUCKET")"
OUTPUT="$(os_uri hourly_rollup "$WAREHOUSE_BUCKET")"

build_pool_run_args
RUN_ID="$(oci data-flow run create \
  --compartment-id "$COMPARTMENT_OCID" \
  --application-id "$APP_ID" \
  --display-name "hourly-aggregate-$(date +%s)" \
  --arguments "$INPUT $OUTPUT" \
  ${POOL_RUN_ARGS[@]+"${POOL_RUN_ARGS[@]}"} \
  --query 'data.id' --raw-output)"

_grn "Run submitted: $RUN_ID"
echo
echo "Re-run this script back-to-back and compare start times:"
echo "  oci data-flow run list --compartment-id $COMPARTMENT_OCID \\"
echo "    --query 'data[].{name:\"display-name\",state:\"lifecycle-state\",created:\"time-created\"}'"
