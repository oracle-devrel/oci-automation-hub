#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# Production bootstrap script for use case 04.
#
# Upload this to Object Storage and point var.bds_bootstrap_script_url at it.
# BDS runs it on EVERY node at cluster creation. Use it to apply consistent
# Spark/YARN tuning, install OS packages, deploy keytabs, etc.
#
# Environment provided by BDS:
#   $HOSTTYPE — MASTER | UTILITY | WORKER | COMPUTE_ONLY_WORKER
#   $CLUSTER_VERSION
#   $CLUSTER_PROFILE
#
# All output is captured in /var/logs/oracle/bds/bootstrap.log on the node.

set -euo pipefail

echo "Bootstrap starting on $(hostname) — type=${HOSTTYPE:-unknown} version=${CLUSTER_VERSION:-?}"

# ---------------------------------------------------------------------------
# Spark tuning — applied wherever Spark executors run (workers + compute-only).
# These mirror sensible production defaults: adaptive query execution, Kryo
# serialization, and dynamic allocation so YARN can right-size jobs.
# ---------------------------------------------------------------------------
if [[ "${HOSTTYPE:-}" == "WORKER" || "${HOSTTYPE:-}" == "COMPUTE_ONLY_WORKER" || "${HOSTTYPE:-}" == "MASTER" ]]; then
  SPARK_DEFAULTS=/etc/spark3/conf/spark-defaults.conf
  if [[ -f "$SPARK_DEFAULTS" ]]; then
    if ! grep -q "stack bootstrap" "$SPARK_DEFAULTS"; then
      {
        echo ""
        echo "# --- Added by stack bootstrap (use case 04) ---"
        echo "spark.sql.adaptive.enabled                       true"
        echo "spark.sql.adaptive.coalescePartitions.enabled    true"
        echo "spark.sql.adaptive.skewJoin.enabled              true"
        echo "spark.serializer                                 org.apache.spark.serializer.KryoSerializer"
        echo "spark.shuffle.service.enabled                    true"
        echo "spark.dynamicAllocation.enabled                  true"
        echo "spark.dynamicAllocation.minExecutors             2"
        echo "spark.dynamicAllocation.maxExecutors             50"
        echo "spark.dynamicAllocation.executorIdleTimeout      120s"
      } >> "$SPARK_DEFAULTS"
      echo "Applied Spark tuning to $SPARK_DEFAULTS"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Compute-only workers: label them so YARN scheduling/placement policies can
# prefer them for transient Spark executors (they carry no HDFS data).
# ---------------------------------------------------------------------------
if [[ "${HOSTTYPE:-}" == "COMPUTE_ONLY_WORKER" ]]; then
  echo "This is an elastic compute-only worker — no DataNode role expected here."
fi

# ---------------------------------------------------------------------------
# Example hooks you'd typically add in production (left as comments):
#   - install monitoring agents / OS packages:  yum install -y <pkg>
#   - deploy service keytabs for Kerberos:       cp /path/keytab /etc/security/keytabs/
#   - mount additional storage, set ulimits, etc.
# Note: yarn-site.xml / core-site.xml are managed by Ambari/Cloudera Manager on
# secure clusters — change those through the management UI, not by hand here.
# ---------------------------------------------------------------------------

echo "Bootstrap finished on $(hostname)"
