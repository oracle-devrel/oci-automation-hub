#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# HDFS NameNode entrypoint.
###############################################################################
set -uo pipefail
export HADOOP_CONF_DIR=/hadoop-config
cp /hadoop-config/krb5.conf /etc/krb5.conf 2>/dev/null || true

HDFS_BIN="$(command -v hdfs || echo "$HADOOP_HOME/bin/hdfs")"

# Format the NameNode once; its metadata lives on a PersistentVolume.
if [ ! -d /hadoop/dfs/name/current ]; then
  echo "[namenode] formatting filesystem"
  "$HDFS_BIN" --config /hadoop-config namenode -format -force -nonInteractive \
    || { echo "[namenode] format failed"; exit 1; }
fi

echo "[namenode] starting"
exec "$HDFS_BIN" --config /hadoop-config namenode
