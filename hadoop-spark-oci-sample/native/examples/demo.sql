-- Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
-- The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

-- Showcase Data Flow SQL job. Reads a CSV from Object Storage, aggregates, writes Parquet.
-- Replace the source URI with one of your own (or upload a CSV to the scripts bucket).

CREATE TABLE IF NOT EXISTS sales USING CSV
OPTIONS (
  path  'oci://<bucket>@<namespace>/sales.csv',
  header 'true',
  inferSchema 'true'
);

SELECT
  region,
  product_category,
  COUNT(*) AS order_count,
  SUM(amount) AS total_revenue
FROM sales
GROUP BY region, product_category
ORDER BY total_revenue DESC;
