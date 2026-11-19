#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# HDFS DataNode entrypoint.
###############################################################################
set -uo pipefail
export HADOOP_CONF_DIR=/hadoop-config
cp /hadoop-config/krb5.conf /etc/krb5.conf 2>/dev/null || true

HDFS_BIN="$(command -v hdfs || echo "$HADOOP_HOME/bin/hdfs")"

echo "[datanode] starting"
exec "$HDFS_BIN" --config /hadoop-config datanode
