#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Demo 1 - Spark only (deploy_spark = true)
#
# Proves Spark-on-Kubernetes works: the Spark Operator schedules a driver +
# executors that generate data and run a distributed aggregation, with no
# external storage. Use this with the "spark only" deployment profile.
#
# Run from the operator host:  ./run.sh
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

require_namespace
kubectl -n "$NS" get deploy -l app.kubernetes.io/name=spark-operator >/dev/null 2>&1 \
  || kubectl -n "$NS" get pods | grep -q spark-operator \
  || die "spark-operator not found in namespace $NS (is deploy_spark = true?)"

APP="spark-only-demo"
submit_pyspark "$APP" "$HERE/job.py"
show_proof "$APP"

ok "Demo 1 complete: Spark generated data and aggregated it on Kubernetes."
info "Cleanup: kubectl -n $NS delete sparkapplication $APP configmap ${APP}-code"
