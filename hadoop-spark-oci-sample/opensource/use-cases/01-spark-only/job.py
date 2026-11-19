# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""
Spark-only demo: generate a synthetic dataset entirely in-cluster and run a
distributed aggregation. No external storage is touched - this proves the
Spark-on-Kubernetes engine (driver + executors via the Spark Operator) works.

It models a stream of retail transactions and answers "revenue by region".
The job narrates the transformation as STEP/SCHEMA/SAMPLE lines (input -> logic
-> output, with real data tables) plus PROOF:/RESULT: lines the runner greps.
"""
from pyspark.sql import SparkSession, functions as F


def show(df, n=5):
    # Print an actual Spark table so viewers SEE the data, not just row counts.
    for line in df._jdf.showString(n, 20, False).rstrip("\n").split("\n"):
        print(f"SAMPLE: {line}")


spark = SparkSession.builder.appName("spark-only-demo").getOrCreate()
sc = spark.sparkContext
print(f"PROOF: spark.version={spark.version} executors~={sc.defaultParallelism}")

# ---- STEP 1: INPUT - generate ~5M synthetic transactions on the executors ---
n = 5_000_000
txns = (
    spark.range(n)
    .withColumn("region", (F.col("id") % F.lit(5)).cast("int"))
    .withColumn("category", (F.rand(seed=1) * 8).cast("int"))
    .withColumn("amount", F.round(F.rand(seed=2) * 100, 2))
    .drop("id")
)
generated = txns.count()
print("STEP: 1/3 INPUT - synthetic retail transactions (region, category, amount)")
print(f"SCHEMA: input {txns.schema.simpleString()}")
print(f"PROOF: input_rows={generated}")
show(txns, 5)

# ---- STEP 2: TRANSFORM ------------------------------------------------------
print("STEP: 2/3 TRANSFORM - GROUP BY region -> count(*) AS txns, round(sum(amount),2) AS revenue")

# ---- STEP 3: OUTPUT - distributed aggregation -------------------------------
by_region = (
    txns.groupBy("region")
    .agg(F.count("*").alias("txns"), F.round(F.sum("amount"), 2).alias("revenue"))
    .orderBy("region")
)
rows = by_region.collect()
print("STEP: 3/3 OUTPUT - revenue by region")
print(f"SCHEMA: output {by_region.schema.simpleString()}")
print(f"PROOF: output_rows={len(rows)} (aggregated down from {generated})")
show(by_region, 20)
for r in rows:
    print(f"RESULT: region={r['region']} txns={r['txns']} revenue={r['revenue']}")

top = max(rows, key=lambda r: r["revenue"])
print(f"RESULT: top_region={top['region']} revenue={top['revenue']}")
print("PROOF: spark-only demo OK")

spark.stop()
