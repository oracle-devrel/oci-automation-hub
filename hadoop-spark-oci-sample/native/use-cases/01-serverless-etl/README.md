# Use case 01 — Serverless ETL with Data Flow

**Goal:** run a real ETL job — read raw CSV from Object Storage, clean and
enrich it, write partitioned Parquet to the warehouse bucket — **without
standing up a single server**. You pay only for the seconds the job runs.

This is the cheapest, fastest way to get value out of the stack: no Hadoop
cluster, no warm pool. Just Object Storage + Data Flow.

## Requires in the Resource Manager form

| Field | Value |
|-------|-------|
| Deploy Data Flow (Spark) applications | **on** |
| Create scripts bucket / warehouse bucket | on (default) |
| Deploy operator VM behind OCI Bastion | on |

Deploy BDS can be **off** — that's the point of this use case.

## Run it (on the operator VM)

Connect to the operator via Bastion (see [../README.md](../README.md)), then:

```bash
cd use-cases/01-serverless-etl
./run.sh
```

`run.sh` self-checks that Data Flow is deployed, then:

1. Uploads `customers_etl.py` and `sample_customers.csv` to the scripts bucket.
2. Ensures a Data Flow application `<prefix>-customers-etl` exists (creates it on
   first run, pointing at the uploaded script).
3. Submits a run, passing the input CSV and output path as arguments.

It prints the run OCID and the commands to track it and list the output.

### Inspect the output

The job writes Parquet partitioned by `country`:

```bash
oci os object list -bn "$WAREHOUSE_BUCKET" --prefix customers_clean/
```

(`$WAREHOUSE_BUCKET` is exported from `deployment.env`, which `run.sh` sources.)
Driver logs land in the logs bucket and in **Data Flow → Runs → <run> → Logs**.

## What the job demonstrates

`customers_etl.py` is a compact but realistic ETL:

- Reads CSV with header + schema inference from Object Storage (`oci://` paths).
- Drops rows with null emails, trims/normalizes strings, lower-cases emails.
- Derives a `signup_year` and a `lifetime_value` aggregate per customer.
- Writes **Parquet partitioned by country** to the warehouse bucket — the layout
  a downstream engine (Trino, Spark SQL, Autonomous DB external table) consumes.

Swap in your own CSV (or a glob like `oci://bucket@ns/raw/*.csv`) and the same
application handles it — serverless Spark scales to the data, you don't manage a
cluster.

## If it can't run

If Data Flow isn't deployed, `run.sh` stops with:

```
This use case can't run on the current deployment.
  Data Flow is not deployed. Set 'Deploy Data Flow (Spark) applications' = on.
```

Re-apply the stack with that enabled and retry.
