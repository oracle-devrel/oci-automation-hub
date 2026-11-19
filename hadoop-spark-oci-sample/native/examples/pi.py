# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Estimate Pi using Monte Carlo. Bundled showcase Spark job for OCI Data Flow."""

import sys
from random import random
from operator import add

from pyspark.sql import SparkSession


def main():
    partitions = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    n = 100_000 * partitions

    spark = SparkSession.builder.appName("DataFlowPi").getOrCreate()

    def inside(_):
        x = random() * 2 - 1
        y = random() * 2 - 1
        return 1 if x * x + y * y <= 1 else 0

    count = (
        spark.sparkContext.parallelize(range(1, n + 1), partitions).map(inside).reduce(add)
    )

    print(f"Pi is roughly {4.0 * count / n}")
    spark.stop()


if __name__ == "__main__":
    main()
