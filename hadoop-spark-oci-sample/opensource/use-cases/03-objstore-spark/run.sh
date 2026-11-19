#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Demo 3 - Object Storage + Spark (deploy_object_storage = true, deploy_spark = true)
#
# A Spark job generates data, writes it to the OCI Object Storage bucket over
# oci://, reads it back, aggregates, and writes results back - authenticating
# with OKE Workload Identity (no API keys). Proves the bucket round-trip.
#
# Run from the operator host:  ./run.sh
#
# Env you may need to set:
#   OS_NAMESPACE       Object Storage namespace (from the object_storage_path
#                      output: oci://<bucket>@<OS_NAMESPACE>/). Required if it
#                      cannot be auto-detected.
#   REGION             OCI region id (e.g. eu-frankfurt-1) - recommended.
#   CONNECTOR_VERSION  oci-hdfs-connector version (default below).
#   AUTHENTICATOR      connector auth class for OKE Workload Identity (default
#                      below) - adjust if your connector version differs.
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

require_namespace
BUCKET="${BUCKET:-${NS}-data}"
CONNECTOR_VERSION="${CONNECTOR_VERSION:-3.3.4.1.4.1}" # 3.3.4.1.4.1 added the OKE Workload Identity authenticator
AUTHENTICATOR="${AUTHENTICATOR:-com.oracle.bmc.hdfs.auth.OkeWorkloadIdentityCustomAuthenticator}"

# Best-effort auto-detect of the Object Storage namespace from the operator.
if [ -z "${OS_NAMESPACE:-}" ]; then
  OS_NAMESPACE="$(OCI_CLI_AUTH=instance_principal oci os ns get --query data --raw-output 2>/dev/null || true)"
fi
[ -n "${OS_NAMESPACE:-}" ] || die "set OS_NAMESPACE (see the object_storage_path output: oci://${BUCKET}@<OS_NAMESPACE>/)"

BASE="oci://${BUCKET}@${OS_NAMESPACE}/demo"
info "bucket=$BUCKET os_namespace=$OS_NAMESPACE base=$BASE"
info "connector=oci-hdfs-connector:${CONNECTOR_VERSION} auth=${AUTHENTICATOR}"

REGION_LINE=""
[ -n "${REGION:-}" ] && REGION_LINE="    spark.hadoop.fs.oci.client.regionCodeOrId: \"${REGION}\""

APP="objstore-spark-demo"
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
  arguments: ["$BASE"]
  sparkVersion: "$SPARK_VERSION"
  restartPolicy:
    type: Never
  sparkConf:
    # The oci-hdfs-connector needs Guava >= 27, but Spark 3.5 bundles Guava
    # 14.0.1 in \$SPARK_HOME/jars and it wins on the classpath. userClassPathFirst
    # "fixes" Guava but splits Hadoop AND Jersey across two classloaders
    # (LinkageError / ClassCastException), because it flips class ordering for
    # EVERY shared library, not just Guava. Instead we keep the normal classloader
    # order and simply PREPEND a modern Guava (+ its required failureaccess) via
    # extraClassPath. extraClassPath is fixed at JVM launch, so --packages can't
    # satisfy it; an init container stages the jars into a shared volume first.
    spark.jars.packages: "com.oracle.oci.sdk:oci-hdfs-connector:$CONNECTOR_VERSION"
    spark.jars.ivy: "/tmp/.ivy2"
    spark.driver.extraClassPath: "/opt/extra-jars/guava-32.1.3-jre.jar:/opt/extra-jars/failureaccess-1.0.1.jar"
    spark.executor.extraClassPath: "/opt/extra-jars/guava-32.1.3-jre.jar:/opt/extra-jars/failureaccess-1.0.1.jar"
    spark.hadoop.fs.oci.impl: "com.oracle.bmc.hdfs.BmcFilesystem"
    spark.hadoop.fs.AbstractFileSystem.oci.impl: "com.oracle.bmc.hdfs.Bmc"
    spark.hadoop.fs.oci.client.custom.authenticator: "$AUTHENTICATOR"
$REGION_LINE
  volumes:
    - name: job-code
      configMap: { name: $APP-code }
    - name: extra-jars
      emptyDir: {}
  driver:
    cores: 1
    memory: "1g"
    serviceAccount: $SPARK_SA
    # Stage a modern Guava (+ failureaccess, required by Guava >= 27) so
    # extraClassPath can put it ahead of Spark's Guava 14 on the same classpath.
    # Reuses the Spark image (has python3) - no extra image pull, no CRI-O
    # short-name concern. Egress to Maven Central goes via the NAT gateway.
    initContainers: &fetchjars
      - name: fetch-guava
        image: "$SPARK_IMAGE"
        command:
          - python3
          - -c
          - |
            import urllib.request as u
            b = "https://repo1.maven.org/maven2/com/google/guava"
            u.urlretrieve(b + "/guava/32.1.3-jre/guava-32.1.3-jre.jar", "/opt/extra-jars/guava-32.1.3-jre.jar")
            u.urlretrieve(b + "/failureaccess/1.0.1/failureaccess-1.0.1.jar", "/opt/extra-jars/failureaccess-1.0.1.jar")
        volumeMounts:
          - { name: extra-jars, mountPath: /opt/extra-jars }
    volumeMounts:
      - { name: job-code, mountPath: /opt/spark/jobs }
      - { name: extra-jars, mountPath: /opt/extra-jars }
  executor:
    cores: 1
    instances: 2
    memory: "1g"
    initContainers: *fetchjars
    volumeMounts:
      - { name: job-code, mountPath: /opt/spark/jobs }
      - { name: extra-jars, mountPath: /opt/extra-jars }
YAML

wait_sparkapp "$APP"
show_proof "$APP"
ok "Demo 3 complete: Spark wrote and read data in Object Storage via Workload Identity."
info "Cleanup: kubectl -n $NS delete sparkapplication $APP configmap ${APP}-code"
