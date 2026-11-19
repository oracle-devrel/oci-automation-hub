# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""
Object Storage + Spark demo: generate data, write it to an OCI Object Storage
bucket over oci://, read it back, aggregate, and write the results back to the
bucket. Authentication is OKE Workload Identity (no keys) via the OCI HDFS
connector. Proves the bucket round-trip + compute.

The job narrates the transformation as STEP/SCHEMA/SAMPLE lines (input -> round
-trip -> logic -> output, with real data tables) plus PROOF:/RESULT: lines.

Arg: <oci-base-path>  e.g. oci://bigdata-data@<os-namespace>/demo
"""
import sys
from pyspark.sql import SparkSession, functions as F


def show(df, n=5):
    # Print an actual Spark table so viewers SEE the data, not just row counts.
    for line in df._jdf.showString(n, 20, False).rstrip("\n").split("\n"):
        print(f"SAMPLE: {line}")


base = sys.argv[1].rstrip("/")
inp, outp = base + "/input", base + "/output"

spark = SparkSession.builder.appName("objstore-spark-demo").getOrCreate()
print(f"PROOF: spark.version={spark.version}")

# ---- STEP 1: INPUT - generate transactions and write them to Object Storage -
df = (
    spark.range(100000)
    .withColumn("category", (F.rand(seed=1) * 8).cast("int"))
    .withColumn("amount", F.round(F.rand(seed=2) * 1000, 2))
    .drop("id")
)
print("STEP: 1/4 INPUT - synthetic transactions generated in-cluster")
print(f"SCHEMA: input {df.schema.simpleString()}")
show(df, 5)
df.write.mode("overwrite").option("header", True).csv(inp)
print(f"PROOF: wrote_input_to_object_storage={inp}")

# ---- STEP 2: ROUND-TRIP - read the data back from Object Storage ------------
back = spark.read.option("header", True).csv(inp)
rows = back.count()
print("STEP: 2/4 ROUND-TRIP - read the data back from Object Storage over oci://")
print(f"PROOF: read_back_rows={rows}")
show(back, 5)

# ---- STEP 3: TRANSFORM ------------------------------------------------------
print("STEP: 3/4 TRANSFORM - GROUP BY category -> count(*) AS txns, round(sum(amount),2) AS revenue")

# ---- STEP 4: OUTPUT - aggregate, print, and write back to Object Storage ----
agg = (
    back.groupBy("category")
    .agg(
        F.count("*").alias("txns"),
        F.round(F.sum(F.col("amount").cast("double")), 2).alias("revenue"),
    )
    .orderBy("category")
)
result = agg.collect()
print("STEP: 4/4 OUTPUT - revenue by category (written back to Object Storage)")
print(f"SCHEMA: output {agg.schema.simpleString()}")
print(f"PROOF: output_rows={len(result)} (aggregated down from {rows})")
show(agg, 20)
for r in result:
    print(f"RESULT: category={r['category']} txns={r['txns']} revenue={r['revenue']}")

agg.coalesce(1).write.mode("overwrite").option("header", True).csv(outp)
print(f"PROOF: wrote_results_to_object_storage={outp}")
spark.stop()
