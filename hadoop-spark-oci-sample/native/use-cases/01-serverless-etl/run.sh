#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Use case 01 — Serverless ETL. Run this ON the operator VM.
#
# Self-checks that Data Flow is deployed, uploads the job + sample data to the
# scripts bucket, ensures a Data Flow application exists, and submits a run.
# No arguments needed — everything comes from deployment.env.
###############################################################################
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

require_dataflow
require_scripts_bucket
require_warehouse_bucket

# 1. Stage the job and a sample input in the scripts bucket.
put_script "$HERE/customers_etl.py" "customers_etl.py"
put_script "$HERE/sample_customers.csv" "sample_customers.csv"

# 2. Ensure the Data Flow application exists (created on first run).
APP_NAME="${RESOURCE_PREFIX}-customers-etl"
FILE_URI="$(os_uri customers_etl.py "$SCRIPTS_BUCKET")"
APP_ID="$(ensure_dataflow_app "$APP_NAME" PYTHON 3.5.0 "$FILE_URI" 2 1 16 2 32)"
_grn "Application: $APP_NAME ($APP_ID)"

# 3. Submit a run (matching the warm-pool shape if a pool is attached).
INPUT="$(os_uri sample_customers.csv "$SCRIPTS_BUCKET")"
OUTPUT="$(os_uri customers_clean "$WAREHOUSE_BUCKET")"
echo "Submitting run:  input=$INPUT  output=$OUTPUT"

build_pool_run_args
RUN_ID="$(oci data-flow run create \
  --compartment-id "$COMPARTMENT_OCID" \
  --application-id "$APP_ID" \
  --display-name "customers-etl-$(date +%s)" \
  --arguments "$INPUT $OUTPUT" \
  ${POOL_RUN_ARGS[@]+"${POOL_RUN_ARGS[@]}"} \
  --query 'data.id' --raw-output)"

_grn "Run submitted: $RUN_ID"
echo
echo "Track it:   oci data-flow run get --run-id $RUN_ID --query 'data.\"lifecycle-state\"'"
echo "Output:     oci os object list -bn $WAREHOUSE_BUCKET --prefix customers_clean/"
