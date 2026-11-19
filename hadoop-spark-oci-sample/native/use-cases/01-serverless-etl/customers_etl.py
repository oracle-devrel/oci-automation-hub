# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Serverless ETL showcase for OCI Data Flow.

Reads a raw customers CSV from Object Storage, cleans and enriches it, and writes
Parquet partitioned by country to the warehouse bucket.

Usage (arguments are passed through `oci data-flow run create --arguments`):

    customers_etl.py <input_uri> <output_uri>

Both URIs are oci:// paths, e.g.
    oci://demo-dataflow-scripts@<ns>/sample_customers.csv
    oci://demo-dataflow-warehouse@<ns>/customers_clean
"""

import sys

from pyspark.sql import SparkSession, functions as F


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: customers_etl.py <input_uri> <output_uri>")

    input_uri, output_uri = sys.argv[1], sys.argv[2]

    spark = SparkSession.builder.appName("customers-etl").getOrCreate()

    raw = (
        spark.read.option("header", "true")
        .option("inferSchema", "true")
        .csv(input_uri)
    )

    print(f"Read {raw.count()} raw rows from {input_uri}")

    cleaned = (
        raw
        # Drop rows we can't key on.
        .filter(F.col("email").isNotNull() & (F.trim(F.col("email")) != ""))
        # Normalize text fields.
        .withColumn("email", F.lower(F.trim(F.col("email"))))
        .withColumn("country", F.upper(F.trim(F.col("country"))))
        .withColumn("name", F.initcap(F.trim(F.col("name"))))
        # Derive a signup_year for downstream cohort analysis.
        .withColumn("signup_year", F.year(F.to_date("signup_date")))
        # Coerce spend to a clean numeric.
        .withColumn("amount", F.col("amount").cast("double"))
        # De-duplicate on the natural key, keep highest spend.
        .dropDuplicates(["email"])
    )

    # Roll spend up to a lifetime_value per customer (here one row each, but the
    # same shape works when the source has many orders per customer).
    enriched = (
        cleaned.groupBy("email", "name", "country", "signup_year")
        .agg(
            F.round(F.sum("amount"), 2).alias("lifetime_value"),
            F.count(F.lit(1)).alias("order_count"),
        )
    )

    written = enriched.count()
    print(f"Writing {written} cleaned customer rows to {output_uri}")

    (
        enriched.repartition("country")
        .write.mode("overwrite")
        .partitionBy("country")
        .parquet(output_uri)
    )

    print("ETL complete.")
    spark.stop()


if __name__ == "__main__":
    main()
