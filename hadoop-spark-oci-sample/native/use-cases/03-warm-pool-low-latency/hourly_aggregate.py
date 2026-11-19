# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Hourly rollup job for OCI Data Flow, designed to be re-run frequently on a
warm pool. Reads an event log CSV, aggregates per hour and event type, and writes
a compact Parquet rollup the dashboard layer can read.

    hourly_aggregate.py <input_uri> <output_uri>
"""

import sys

from pyspark.sql import SparkSession, functions as F


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: hourly_aggregate.py <input_uri> <output_uri>")

    input_uri, output_uri = sys.argv[1], sys.argv[2]

    spark = SparkSession.builder.appName("hourly-aggregate").getOrCreate()

    events = (
        spark.read.option("header", "true")
        .option("inferSchema", "true")
        .csv(input_uri)
    )

    rollup = (
        events
        .withColumn("event_hour", F.date_trunc("hour", F.col("event_time")))
        .groupBy("event_hour", "event_type")
        .agg(
            F.count(F.lit(1)).alias("event_count"),
            F.countDistinct("user_id").alias("unique_users"),
        )
        .orderBy("event_hour", "event_type")
    )

    rollup.show(truncate=False)

    rollup.write.mode("overwrite").parquet(output_uri)
    print(f"Wrote hourly rollup to {output_uri}")

    spark.stop()


if __name__ == "__main__":
    main()
