#!/usr/bin/env bash
###############################################################################
# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# Shared helpers for the use-case demos. Source this from each run.sh.
#
# Run the demos from the OPERATOR host (it has kubectl + a working kubeconfig).
# Reach the operator through the OCI Bastion - see use-cases/README.md.
###############################################################################
set -euo pipefail

# Load the deployment descriptor written by operator cloud-init. It supplies
# the real namespace/region instead of assuming every cluster is named bigdata.
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USE_CASE_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
if [ -f "$USE_CASE_ROOT/deployment.env" ]; then
  # shellcheck source=/dev/null
  source "$USE_CASE_ROOT/deployment.env"
fi

# ---- Config (override via environment) --------------------------------------
NS="${NS:-${CLUSTER_NAME:-bigdata}}"          # namespace == cluster_name
SPARK_IMAGE="${SPARK_IMAGE:-docker.io/apache/spark:3.5.3}" # fully-qualified: OKE CRI-O enforces short-name mode
SPARK_VERSION="${SPARK_VERSION:-3.5.3}"
SPARK_SA="${SPARK_SA:-spark}"
TIMEOUT="${TIMEOUT:-900}"                     # seconds to wait for a SparkApplication
export OCI_CLI_AUTH="${OCI_CLI_AUTH:-instance_principal}"
[ -n "${REGION:-}" ] && export OCI_CLI_REGION="$REGION"
[ -n "${KUBECONFIG:-}" ] || export KUBECONFIG=/home/opc/.kube/config

# ---- Pretty output ----------------------------------------------------------
log()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

require_namespace() {
  need kubectl
  local api_error bootstrap_state="unknown"
  if ! api_error="$(kubectl get --raw=/readyz 2>&1)"; then
    command -v cloud-init >/dev/null 2>&1 && bootstrap_state="$(cloud-init status 2>/dev/null || true)"
    die "Kubernetes API unavailable via $KUBECONFIG ($bootstrap_state). ${api_error##*$'\n'}"
  fi
  kubectl get ns "$NS" >/dev/null 2>&1 || \
    die "Kubernetes API is ready, but namespace '$NS' does not exist (deployed cluster_name=$NS)"
}

# Wait for a SparkApplication to reach a terminal state.
wait_sparkapp() {
  local name="$1" state="" i=0
  log "waiting for SparkApplication/$name (timeout ${TIMEOUT}s)"
  while (( i < TIMEOUT )); do
    state="$(kubectl -n "$NS" get sparkapplication "$name" \
      -o jsonpath='{.status.applicationState.state}' 2>/dev/null || true)"
    info "state=${state:-PENDING} (${i}s)"
    case "$state" in
      COMPLETED) ok "SparkApplication/$name COMPLETED"; return 0 ;;
      FAILED|FAILING|INVALIDATING|UNKNOWN)
        driver_logs "$name"; die "SparkApplication/$name -> $state" ;;
    esac
    sleep 10; (( i += 10 ))
  done
  driver_logs "$name"; die "SparkApplication/$name timed out after ${TIMEOUT}s"
}

driver_logs() {
  echo "------------------------- driver logs ($1-driver) -------------------------"
  kubectl -n "$NS" logs "$1-driver" 2>/dev/null || info "(driver pod not found yet)"
  echo "---------------------------------------------------------------------------"
}

# Print the transformation story + evidence the job emitted. STEP/SCHEMA/SAMPLE
# narrate input -> transform -> output (with real data tables); PROOF/RESULT are
# the machine-checkable evidence.
show_proof() {
  local name="$1"
  log "transformation + proof from $name driver logs"
  kubectl -n "$NS" logs "$1-driver" 2>/dev/null | grep -E '^(STEP|SCHEMA|SAMPLE|PROOF|RESULT):' \
    || die "no STEP/PROOF/RESULT lines found - the job did not produce evidence"
}

# Submit a PySpark job from a local .py file (delivered via a ConfigMap).
# Usage: submit_pyspark <name> <pyfile> [extra "spark.conf.key=value"...]
submit_pyspark() {
  local name="$1" pyfile="$2"; shift 2
  [ -f "$pyfile" ] || die "job file not found: $pyfile"

  local conf=""
  for kv in "$@"; do conf+="    ${kv%%=*}: \"${kv#*=}\""$'\n'; done

  log "submitting SparkApplication/$name (image=$SPARK_IMAGE)"
  kubectl -n "$NS" delete sparkapplication "$name" >/dev/null 2>&1 || true
  kubectl -n "$NS" create configmap "$name-code" --from-file=job.py="$pyfile" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl apply -f - <<YAML >/dev/null
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: $name
  namespace: $NS
spec:
  type: Python
  pythonVersion: "3"
  mode: cluster
  image: "$SPARK_IMAGE"
  imagePullPolicy: IfNotPresent
  mainApplicationFile: "local:///opt/spark/jobs/job.py"
  sparkVersion: "$SPARK_VERSION"
  restartPolicy:
    type: Never
  sparkConf:
$conf
  volumes:
    - name: job-code
      configMap:
        name: $name-code
  driver:
    cores: 1
    memory: "1g"
    serviceAccount: $SPARK_SA
    volumeMounts:
      - name: job-code
        mountPath: /opt/spark/jobs
  executor:
    cores: 1
    instances: 2
    memory: "1g"
    volumeMounts:
      - name: job-code
        mountPath: /opt/spark/jobs
YAML

  wait_sparkapp "$name"
}
