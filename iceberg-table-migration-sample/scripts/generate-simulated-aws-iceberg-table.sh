#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

BUCKET="${BUCKET:-iceberg-table-demo}"
TABLE_PREFIX="${TABLE_PREFIX:-lakehouse/sales/orders}"
CATALOG_WAREHOUSE_DIR="${CATALOG_WAREHOUSE_DIR:-/opt/iceberg/aws_source_catalog}"
CATALOG_WAREHOUSE="${CATALOG_WAREHOUSE:-s3://${BUCKET}/lakehouse}"
JDBC_CATALOG_URI="${JDBC_CATALOG_URI:-jdbc:postgresql://127.0.0.1:5432/metastore}"
JDBC_CATALOG_USER="${JDBC_CATALOG_USER:-hive}"
JDBC_CATALOG_PASSWORD="${JDBC_CATALOG_PASSWORD:-hive}"
DATABASE="${DATABASE:-sales}"
TABLE="${TABLE:-orders}"
ICEBERG_VERSION="${ICEBERG_VERSION:-1.10.1}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-fakeaws}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-fakeawssecret}"
EXPORT_ROOT="${EXPORT_ROOT:-/opt/iceberg/generated_aws_source}"
EXPORT_DIR="${EXPORT_ROOT}/${BUCKET}/${TABLE_PREFIX}"

mkdir -p /opt/iceberg/simulated-aws-s3
mkdir -p "${CATALOG_WAREHOUSE_DIR}"
cat >/opt/iceberg/simulated-aws-s3/docker-compose.yml <<MINIO_EOF
services:
  minio:
    image: docker.io/pgsty/silo:RELEASE.2026-11-12T00-00-00Z
    container_name: simulated-aws-s3
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ACCESS_KEY}
      MINIO_ROOT_PASSWORD: ${MINIO_SECRET_KEY}
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"
    volumes:
      - simulated_aws_s3:/data

volumes:
  simulated_aws_s3:
MINIO_EOF

docker compose -f /opt/iceberg/simulated-aws-s3/docker-compose.yml up -d

until curl -sf "${MINIO_ENDPOINT}/minio/health/live" >/dev/null; do
  echo "Waiting for simulated AWS S3..."
  sleep 2
done

export AWS_ACCESS_KEY_ID="${MINIO_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${MINIO_SECRET_KEY}"
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="us-east-1"

aws --endpoint-url "${MINIO_ENDPOINT}" s3 mb "s3://${BUCKET}" 2>/dev/null || true
aws --endpoint-url "${MINIO_ENDPOINT}" s3 rm "s3://${BUCKET}/${TABLE_PREFIX}" --recursive || true

cat >/tmp/create-simulated-aws-iceberg-table.sql <<SQL_EOF
CREATE NAMESPACE IF NOT EXISTS aws_source.${DATABASE};

DROP TABLE IF EXISTS aws_source.${DATABASE}.${TABLE};

CREATE TABLE aws_source.${DATABASE}.${TABLE} (
  order_id BIGINT,
  customer_id STRING,
  order_total DECIMAL(10,2),
  order_date DATE
)
USING iceberg
LOCATION 's3://${BUCKET}/${TABLE_PREFIX}';

INSERT INTO aws_source.${DATABASE}.${TABLE} VALUES
  (1001, 'CUST-001', CAST(125.50 AS DECIMAL(10,2)), DATE '2026-01-05'),
  (1002, 'CUST-002', CAST(89.99 AS DECIMAL(10,2)), DATE '2026-01-06'),
  (1003, 'CUST-003', CAST(240.00 AS DECIMAL(10,2)), DATE '2026-01-07');

SELECT COUNT(*) AS row_count FROM aws_source.${DATABASE}.${TABLE};
SQL_EOF

/opt/spark/bin/spark-sql \
  --jars /opt/iceberg/jars/postgresql.jar \
  --packages "org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:${ICEBERG_VERSION},org.apache.iceberg:iceberg-aws-bundle:${ICEBERG_VERSION}" \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.aws_source=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.aws_source.type=jdbc \
  --conf spark.sql.catalog.aws_source.uri="${JDBC_CATALOG_URI}" \
  --conf spark.sql.catalog.aws_source.jdbc.user="${JDBC_CATALOG_USER}" \
  --conf spark.sql.catalog.aws_source.jdbc.password="${JDBC_CATALOG_PASSWORD}" \
  --conf spark.sql.catalog.aws_source.warehouse="${CATALOG_WAREHOUSE}" \
  --conf spark.sql.catalog.aws_source.io-impl=org.apache.iceberg.aws.s3.S3FileIO \
  --conf spark.sql.catalog.aws_source.s3.endpoint="${MINIO_ENDPOINT}" \
  --conf spark.sql.catalog.aws_source.s3.path-style-access=true \
  --conf spark.sql.catalog.aws_source.client.region="us-east-1" \
  --conf spark.sql.catalog.aws_source.s3.access-key-id="${MINIO_ACCESS_KEY}" \
  --conf spark.sql.catalog.aws_source.s3.secret-access-key="${MINIO_SECRET_KEY}" \
  -f /tmp/create-simulated-aws-iceberg-table.sql

rm -rf "${EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}"
aws --endpoint-url "${MINIO_ENDPOINT}" s3 sync "s3://${BUCKET}/${TABLE_PREFIX}/" "${EXPORT_DIR}/"

find "${EXPORT_DIR}" -type f | sort
echo
echo "Generated real Iceberg source simulation at: ${EXPORT_DIR}"
echo "Pretend source path: s3://${BUCKET}/${TABLE_PREFIX}/"
