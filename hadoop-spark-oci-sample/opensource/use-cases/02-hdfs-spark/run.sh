#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Demo 2 - HDFS + Spark (deploy_hdfs = true, deploy_spark = true)
#
# Part A (core proof): authenticate to the KDC and write/read data in
#   Kerberos-secured HDFS directly from the NameNode pod.
# Part B (integration): run a Spark job that reads that data from HDFS using a
#   keytab, aggregates it, and writes results back to HDFS.
#
# Run from the operator host:  ./run.sh
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

require_namespace
NN_POD="${NN_POD:-namenode-0}"
KDC_POD="${KDC_POD:-kdc-0}"
HDFS_FS="hdfs://${NN_POD}.hdfs-nn.${NS}.svc.cluster.local:9000"
IN="${HDFS_FS}/demo/input"
OUT="${HDFS_FS}/demo/output"

kubectl -n "$NS" get pod "$NN_POD" >/dev/null 2>&1 || die "$NN_POD not found (is deploy_hdfs = true and the pod Running?)"

# Realm + the hadoop principal's password (from the Kerberos secret).
REALM="${REALM:-$(kubectl -n "$NS" get cm kdc-config -o go-template='{{index .data "krb5.conf"}}' 2>/dev/null | sed -n 's/.*default_realm = //p' | head -1)}"
REALM="${REALM:-HADOOP.INTERNAL}"
KPW="$(kubectl -n "$NS" get secret kerberos-creds -o jsonpath='{.data.HADOOP_USER_PASSWORD}' | base64 -d)"
info "realm=$REALM namenode=$NN_POD"

############################### Part A: HDFS ##################################
log "Part A - generate data and land it in secured HDFS"

# Generate a synthetic CSV locally, then stream it into HDFS via the pod.
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
awk 'BEGIN{srand(7);print "category,amount";for(i=0;i<100000;i++)printf "%d,%.2f\n",int(rand()*8),rand()*1000}' > "$TMP"
info "generated $(wc -l <"$TMP") lines locally"

# HADOOP_CONF_DIR must point at the mounted config, or the hdfs CLI defaults to
# fs.defaultFS=file:/// and writes to the pod's LOCAL disk instead of HDFS (an
# interactive `kubectl exec` shell doesn't inherit the entrypoint's env).
HC="export HADOOP_CONF_DIR=/hadoop-config;"

# HDFS root "/" is owned by the hdfs superuser, so the hadoop end-user cannot
# create /demo. Provision it as the superuser (using the NameNode's own keytab)
# and hand ownership to hadoop. The exact hdfs principal - its _HOST resolves to
# the pod's reverse-DNS name - is read straight from the keytab, so we never guess.
kubectl -n "$NS" exec "$NN_POD" -- bash -lc "$HC"' P=$(klist -kt /keytabs/hdfs.keytab | awk "/hdfs\//{print \$NF; exit}"); kinit -kt /keytabs/hdfs.keytab "$P" && hdfs dfs -mkdir -p /demo && hdfs dfs -chown hadoop:hadoop /demo' || die "failed to provision /demo as the hdfs superuser"
ok "provisioned /demo in HDFS (owner hadoop) via the hdfs superuser"

# kinit as the hadoop end-user (password via stdin, never on the command line).
# Proves user auth works and leaves hadoop's ticket in the pod cache for the write.
printf '%s' "$KPW" | kubectl -n "$NS" exec -i "$NN_POD" -- \
  bash -lc "kinit hadoop@$REALM && klist" || die "kinit failed"
ok "kinit hadoop@$REALM succeeded (Kerberos auth works)"

kubectl -n "$NS" exec -i "$NN_POD" -- bash -lc "$HC hdfs dfs -mkdir -p /demo/input && hdfs dfs -put -f - /demo/input/data.csv" < "$TMP"
kubectl -n "$NS" exec "$NN_POD" -- bash -lc "$HC"' echo "HDFS listing:"; hdfs dfs -ls /demo/input; echo "HDFS head:"; hdfs dfs -cat /demo/input/data.csv | head -3'
ok "Part A complete: data written to and read from Kerberos-secured HDFS."

############################### Part B: Spark #################################
log "Part B - Spark reads HDFS with a keytab, aggregates, writes back"

# Export a keytab for hadoop@REALM from the KDC (norandkey keeps the password key).
if kubectl -n "$NS" get pod "$KDC_POD" >/dev/null 2>&1; then
  kubectl -n "$NS" exec "$KDC_POD" -- bash -lc \
    "kadmin.local -q 'ktadd -norandkey -k /tmp/hadoop.keytab hadoop@$REALM'" >/dev/null
  kubectl -n "$NS" exec "$KDC_POD" -- cat /tmp/hadoop.keytab > "$TMP.keytab"
  # spark.kerberos.keytab is read by the SUBMITTER - the spark-operator pod that
  # runs spark-submit - which then distributes the keytab to the driver. So the
  # keytab must exist ON THE OPERATOR POD, not just mounted in the driver.
  OP="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=spark-operator -o jsonpath='{.items[0].metadata.name}')"
  [ -n "$OP" ] || die "spark-operator pod not found"
  base64 "$TMP.keytab" | kubectl -n "$NS" exec -i "$OP" -- sh -c 'base64 -d > /tmp/hadoop.keytab'
  rm -f "$TMP.keytab"
  ok "keytab for hadoop@$REALM placed on the spark-operator (submitter) pod: $OP"
else
  die "$KDC_POD not found - cannot export a keytab for the Spark job"
fi

APP="hdfs-spark-demo"
kubectl -n "$NS" delete sparkapplication "$APP" >/dev/null 2>&1 || true
kubectl -n "$NS" create configmap "$APP-code" --from-file=job.py="$HERE/job.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - <<YAML >/dev/null
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: $APP
  namespace: $NS
spec:
  type: Python
  pythonVersion: "3"
  mode: cluster
  image: "$SPARK_IMAGE"
  imagePullPolicy: IfNotPresent
  mainApplicationFile: "local:///opt/spark/jobs/job.py"
  arguments: ["$IN", "$OUT"]
  sparkVersion: "$SPARK_VERSION"
  restartPolicy:
    type: Never
  sparkConf:
    # keytab path is on the submitter (operator) pod; Spark distributes it to
    # the driver, which logs in and fetches HDFS delegation tokens.
    spark.kerberos.principal: "hadoop@$REALM"
    spark.kerberos.keytab: "/tmp/hadoop.keytab"
    spark.kerberos.access.hadoopFileSystems: "$HDFS_FS"
    spark.hadoop.hadoop.security.authentication: "kerberos"
  volumes:
    - name: job-code
      configMap: { name: $APP-code }
    - name: hadoop-conf
      configMap: { name: hadoop-config }
    - name: krb5
      configMap: { name: kdc-config }
  driver:
    cores: 1
    memory: "1g"
    serviceAccount: $SPARK_SA
    env:
      - { name: HADOOP_CONF_DIR, value: /opt/hadoop/conf }
    volumeMounts: &mounts
      - { name: job-code, mountPath: /opt/spark/jobs }
      - { name: hadoop-conf, mountPath: /opt/hadoop/conf }
      - { name: krb5, mountPath: /etc/krb5.conf, subPath: krb5.conf }
  executor:
    cores: 1
    instances: 2
    memory: "1g"
    env:
      - { name: HADOOP_CONF_DIR, value: /opt/hadoop/conf }
    volumeMounts: *mounts
YAML

wait_sparkapp "$APP"
show_proof "$APP"

log "verifying the Spark output landed in HDFS"
kubectl -n "$NS" exec "$NN_POD" -- bash -lc "$HC"' echo "OUTPUT:"; hdfs dfs -ls /demo/output; hdfs dfs -cat /demo/output/part-*.csv | head -10'

ok "Demo 2 complete: secured HDFS + Spark read/write proven end to end."
info "Cleanup: kubectl -n $NS delete sparkapplication $APP configmap ${APP}-code"
