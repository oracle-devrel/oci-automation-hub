# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""
HDFS + Spark demo: read a CSV that was landed in Kerberos-secured HDFS, run a
distributed aggregation, and write the results back to HDFS. Proves Spark can
authenticate to secured HDFS (via a keytab) and read/write it.

The job narrates the transformation as STEP/SCHEMA/SAMPLE lines (input -> logic
-> output, with real data tables) plus PROOF:/RESULT: lines the runner greps.

Args: <hdfs-input-path> <hdfs-output-path>
"""
import sys
from pyspark.sql import SparkSession, functions as F


def show(df, n=5):
    # Print an actual Spark table so viewers SEE the data, not just row counts.
    for line in df._jdf.showString(n, 20, False).rstrip("\n").split("\n"):
        print(f"SAMPLE: {line}")


src, dst = sys.argv[1], sys.argv[2]
spark = SparkSession.builder.appName("hdfs-spark-demo").getOrCreate()
print(f"PROOF: spark.version={spark.version}")
print(f"PROOF: defaultFS={spark.sparkContext._jsc.hadoopConfiguration().get('fs.defaultFS')}")

# ---- STEP 1: INPUT - read the CSV from Kerberos-secured HDFS ----------------
df = spark.read.option("header", True).csv(src)
rows = df.count()
print("STEP: 1/3 INPUT - CSV read from Kerberos-secured HDFS")
print(f"SCHEMA: input {df.schema.simpleString()}")
print(f"PROOF: read_rows_from_hdfs={rows} src={src}")
show(df, 5)

# ---- STEP 2: TRANSFORM ------------------------------------------------------
print("STEP: 2/3 TRANSFORM - GROUP BY category -> count(*) AS txns, round(sum(amount),2) AS revenue")

# ---- STEP 3: OUTPUT - aggregate, print, and write back to HDFS --------------
agg = (
    df.groupBy("category")
    .agg(
        F.count("*").alias("txns"),
        F.round(F.sum(F.col("amount").cast("double")), 2).alias("revenue"),
    )
    .orderBy("category")
)
result = agg.collect()
print("STEP: 3/3 OUTPUT - revenue by category (written back to HDFS)")
print(f"SCHEMA: output {agg.schema.simpleString()}")
print(f"PROOF: output_rows={len(result)} (aggregated down from {rows})")
show(agg, 20)
for r in result:
    print(f"RESULT: category={r['category']} txns={r['txns']} revenue={r['revenue']}")

agg.coalesce(1).write.mode("overwrite").option("header", True).csv(dst)
print(f"PROOF: wrote_results_to_hdfs={dst}")
spark.stop()
