#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Kerberos KDC entrypoint (runs in the kdc StatefulSet pod).
# Environment: REALM, KDC_DB_PASSWORD, KADMIN_PASSWORD, HADOOP_USER_PASSWORD
###############################################################################
set -uo pipefail
echo "[kdc] starting; realm=$REALM"

# Install the krb5 server on the upstream base image (a prebuilt OCIR image
# already has it - this is then a no-op).
if ! command -v kdb5_util >/dev/null 2>&1; then
  echo "[kdc] installing krb5-server"
  dnf install -y krb5-server krb5-workstation || { echo "[kdc] package install failed"; exit 1; }
fi

# /etc/krb5.conf and the realm-dir config come from the mounted ConfigMap.
cp /kdc-config/krb5.conf /etc/krb5.conf
mkdir -p /var/kerberos/krb5kdc
cp /kdc-config/kdc.conf  /var/kerberos/krb5kdc/kdc.conf
cp /kdc-config/kadm5.acl /var/kerberos/krb5kdc/kadm5.acl

# Initialise the realm database once - it lives on a PersistentVolume.
if [ ! -f /var/kerberos/krb5kdc/principal ]; then
  echo "[kdc] creating realm database"
  kdb5_util create -s -r "$REALM" -P "$KDC_DB_PASSWORD" || { echo "[kdc] kdb5_util failed"; exit 1; }
  kadmin.local -q "addprinc -pw $KADMIN_PASSWORD admin/admin@$REALM"
  kadmin.local -q "addprinc -pw $HADOOP_USER_PASSWORD hadoop@$REALM"
  echo "[kdc] realm initialised"
fi

# Start the KDC (forks), then run the admin server in the foreground so the
# container's lifecycle tracks kadmind.
echo "[kdc] starting krb5kdc + kadmind"
krb5kdc
exec kadmind -nofork
