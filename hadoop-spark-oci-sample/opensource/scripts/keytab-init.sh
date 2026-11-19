#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# HDFS keytab init-container.
#
# Creates this pod's Kerberos service principals against the KDC and extracts a
# keytab into the shared /keytabs volume that the main container consumes.
# Environment: REALM, KADMIN_PASSWORD, POD_SERVICE, POD_NAMESPACE
###############################################################################
set -uo pipefail

# Build the FQDN deterministically from the pod's stable network identity, using
# the Downward API (POD_NAME=metadata.name). Do NOT use `hostname`/`hostname -f`:
# the base image has no reliable hostname resolution (returns empty), and the
# pod's resolv.conf search domains don't include the governing service subdomain
# - either way the wrong principal gets baked into the keytab. This matches the
# DNS name HDFS resolves _HOST to (reverse DNS of the pod IP).
: "${POD_NAME:?POD_NAME is required}"
: "${POD_SERVICE:?POD_SERVICE is required}"
: "${POD_NAMESPACE:?POD_NAMESPACE is required}"
FQDN="${POD_NAME}.${POD_SERVICE}.${POD_NAMESPACE}.svc.cluster.local"
echo "[keytab-init] host=$FQDN"

if ! command -v kadmin >/dev/null 2>&1; then
  echo "[keytab-init] installing krb5-workstation"
  dnf install -y krb5-workstation || { echo "[keytab-init] package install failed"; exit 1; }
fi
cp /kdc-config/krb5.conf /etc/krb5.conf

KADM="kadmin -p admin/admin@$REALM -w $KADMIN_PASSWORD"

# Wait for the KDC / kadmind to answer.
ready=""
for i in $(seq 1 60); do
  if $KADM -q "get_principal admin/admin@$REALM" >/dev/null 2>&1; then
    ready="yes"; break
  fi
  echo "[keytab-init] waiting for KDC ($i/60)"; sleep 5
done
[ -z "$ready" ] && { echo "[keytab-init] KDC never became reachable"; exit 1; }

# Create this pod's principals (idempotent) and extract a single keytab.
for p in "hdfs/$FQDN" "HTTP/$FQDN"; do
  $KADM -q "addprinc -randkey $p" >/dev/null 2>&1 || true
done
rm -f /keytabs/hdfs.keytab
if ! $KADM -q "ktadd -k /keytabs/hdfs.keytab hdfs/$FQDN HTTP/$FQDN"; then
  echo "[keytab-init] ktadd failed"; exit 1
fi
chmod 600 /keytabs/hdfs.keytab
echo "[keytab-init] keytab written for $FQDN"
