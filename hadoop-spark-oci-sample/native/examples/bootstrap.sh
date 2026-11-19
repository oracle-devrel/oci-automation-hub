#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# Example BDS bootstrap script. Upload this to Object Storage and point
# var.bds_bootstrap_script_url at it.
#
# BDS executes this on every node at cluster creation. Use it to customise
# Hadoop / Spark configuration files, install OS packages, deploy keytabs,
# etc.
#
# Useful environment variables provided by BDS:
#   $HOSTTYPE — MASTER | UTILITY | WORKER | COMPUTE_ONLY_WORKER
#   $CLUSTER_VERSION
#   $CLUSTER_PROFILE
#
# All output goes to /var/logs/oracle/bds/bootstrap.log on the node.

set -euo pipefail

echo "Bootstrap starting on $(hostname) — type=${HOSTTYPE:-unknown}"

# ---------------------------------------------------------------------------
# Spark tuning — applied on master + worker nodes
# ---------------------------------------------------------------------------
if [[ "${HOSTTYPE:-}" == "MASTER" || "${HOSTTYPE:-}" == "WORKER" || "${HOSTTYPE:-}" == "COMPUTE_ONLY_WORKER" ]]; then
  SPARK_DEFAULTS=/etc/spark3/conf/spark-defaults.conf
  if [[ -f "$SPARK_DEFAULTS" ]]; then
    {
      echo ""
      echo "# Added by stack bootstrap"
      echo "spark.sql.adaptive.enabled                       true"
      echo "spark.sql.adaptive.coalescePartitions.enabled    true"
      echo "spark.serializer                                 org.apache.spark.serializer.KryoSerializer"
      echo "spark.shuffle.service.enabled                    true"
      echo "spark.dynamicAllocation.enabled                  true"
    } >> "$SPARK_DEFAULTS"
  fi
fi

# ---------------------------------------------------------------------------
# YARN tuning — applied on master nodes
# ---------------------------------------------------------------------------
if [[ "${HOSTTYPE:-}" == "MASTER" ]]; then
  YARN_SITE=/etc/hadoop/conf/yarn-site.xml
  if [[ -f "$YARN_SITE" ]]; then
    echo "yarn-site.xml already managed by Ambari/Cloudera Manager; edit there instead."
  fi
fi

echo "Bootstrap finished on $(hostname)"
