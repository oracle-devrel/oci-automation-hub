# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Sales report Spark job for an OCI Big Data Service (Hadoop) cluster.

Runs on YARN via spark-submit. Reads a sales CSV, computes revenue by region and
product category with each category's share of total revenue, and writes a single
CSV report back out.

    spark-submit --master yarn --deploy-mode cluster \\
        sales_report.py <input_path> <output_path>

Paths can be hdfs:///... or oci://bucket@namespace/... — BDS handles both.
"""

import sys

from pyspark.sql import SparkSession, Window, functions as F


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: sales_report.py <input_path> <output_path>")

    input_path, output_path = sys.argv[1], sys.argv[2]

    spark = SparkSession.builder.appName("sales-report").getOrCreate()

    sales = (
        spark.read.option("header", "true")
        .option("inferSchema", "true")
        .csv(input_path)
    )

    by_segment = (
        sales.groupBy("region", "product_category")
        .agg(
            F.count(F.lit(1)).alias("order_count"),
            F.round(F.sum("amount"), 2).alias("total_revenue"),
        )
    )

    # Each segment's share of overall revenue, via a window over everything.
    overall = Window.partitionBy()
    report = (
        by_segment.withColumn(
            "revenue_share_pct",
            F.round(100 * F.col("total_revenue") / F.sum("total_revenue").over(overall), 2),
        )
        .orderBy(F.col("total_revenue").desc())
    )

    report.show(truncate=False)

    # Coalesce to one file so the report is easy to read back from HDFS.
    (
        report.coalesce(1)
        .write.mode("overwrite")
        .option("header", "true")
        .csv(output_path)
    )

    print(f"Wrote sales report to {output_path}")
    spark.stop()


if __name__ == "__main__":
    main()
