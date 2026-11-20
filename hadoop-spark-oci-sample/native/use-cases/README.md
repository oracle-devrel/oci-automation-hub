# Use cases

End-to-end walkthroughs that show what this stack can do. The workflow is:

1. **Deploy the stack once via OCI Resource Manager**, enabling the
   **operator VM** option (and whichever BDS / Data Flow / warm-pool options the
   use cases you want need).
2. **Open an OCI Bastion session and SSH into the operator VM.** The use-case
   scripts are already staged on it.
3. **Run the scripts.** Each one **self-checks what the stack actually
   deployed** and, if a use case can't run on your configuration, tells you
   exactly which Resource Manager form field to change — instead of failing with
   an opaque error.

There are no per-use-case `terraform.tfvars` files: with Resource Manager you
configure everything in the deploy form, and the scripts read what was deployed
from a descriptor (`deployment.env`) that Terraform writes onto the operator.

| # | Use case | Showcases | Needs in the RM form |
|---|----------|-----------|----------------------|
| [01](01-serverless-etl/) | **Serverless ETL** | CSV → cleaned/partitioned Parquet via Data Flow, no cluster | Deploy Data Flow |
| [02](02-hadoop-cluster-analytics/) | **Hadoop cluster analytics** | `spark-submit` on YARN + HDFS on managed BDS | Deploy BDS |
| [03](03-warm-pool-low-latency/) | **Warm-pool low latency** | Repeated jobs with reserved pool capacity | Deploy Data Flow + warm pool |
| [04](04-secure-ha-production/) | **Secure HA production** | Kerberos + Ranger, HA, elastic compute-only workers, bootstrap tuning | Deploy BDS (HA + secure) |

## 1. Deploy via Resource Manager

Zip the repo (exclude `.terraform/`, `*.tfstate*`, `.git/`) and create a Stack in
**Developer Services → Resource Manager → Stacks → Create Stack → upload**. The
form is rendered from `schema.yaml`. For the operator workflow, set:

| Form field | Value |
|------------|-------|
| **Deploy operator VM behind OCI Bastion** | **on** |
| Create an OCI Bastion | on |
| SSH public key | your public key (used to open bastion sessions) |
| Deploy Data Flow / Deploy BDS / warm pool | per the use cases you want (see table) |

Then **Plan → Apply**. Terraform uploads the `use-cases/` directory to the
scripts bucket; the operator boots, installs tooling, writes a `deployment.env`
descriptor of what was deployed, and **pulls the use-case files from the scripts
bucket** with instance-principal auth. This runs entirely within the apply — the
operator fetches its own files, so it works the same from Resource Manager as
from the CLI.

> The operator stages its files from the Data Flow **scripts bucket**, so keep
> "Create scripts bucket" on (default). The first pull retries for a few minutes
> to absorb IAM propagation lag right after boot.

## 2. Connect via OCI Bastion

The operator has **no public IP**; you reach it only through the managed Bastion.
The connection is a two-hop SSH: your laptop → bastion → operator.

### 2a. Open a bastion session and connect

Read the ready-made session command from the stack outputs:

```bash
terraform output -raw operator_bastion_session_hint
```

Run the printed `oci bastion session create-managed-ssh ...` (adjust
`--ssh-public-key-file` to your key), wait for `SUCCEEDED`, then connect. Take
the `<SESSION_OCID>` from the session you created:

```bash
ssh \
  -o ProxyCommand="ssh -i ~/.ssh/id_rsa -W %h:%p -p 22 <SESSION_OCID>@host.bastion.<region>.oci.oraclecloud.com" \
  -i ~/.ssh/id_rsa opc@<OPERATOR_PRIVATE_IP>
```

- `<OPERATOR_PRIVATE_IP>` = `terraform output -raw operator_private_ip`.
- `<region>` e.g. `eu-frankfurt-1`.

### 2b. Verify operator-to-BDS access

When BDS was deployed with the operator, Terraform created a purpose-specific
key at `~/.ssh/bds_operator` and installed its public half on the BDS cluster.
No workstation private key or forwarded agent is needed for this hop:

```bash
test -r ~/.ssh/bds_operator
ssh -i ~/.ssh/bds_operator -o IdentitiesOnly=yes opc@<BDS_UTILITY_IP> hostname
```

For stacks created before this key existed, `BDS_SSH_KEY=/path/to/key` selects
an authorized key already present on the operator. Agent forwarding remains a
compatibility fallback, but is no longer part of the normal workflow.

## 3. Run the use cases

On the operator, start by seeing what the stack deployed:

```bash
cd use-cases
cat deployment.env                 # capability flags + bucket/compartment info
```

Each use case has one entry-point script. They all self-check the deployment
first, so a script that can't run on your configuration tells you exactly which
Resource Manager field to flip instead of failing obscurely.

| # | Use case | Run on the operator | Needs |
|---|----------|---------------------|-------|
| 01 | Serverless ETL | `./01-serverless-etl/run.sh` | Data Flow |
| 02 | Hadoop cluster analytics | `./02-hadoop-cluster-analytics/run.sh` | BDS |
| 03 | Warm-pool low latency | `./03-warm-pool-low-latency/run.sh` | Data Flow (+ warm pool) |
| 04 | Secure HA production | `./04-secure-ha-production/run.sh` | BDS (HA + secure) |

```bash
# Data Flow use cases — submit a serverless Spark run end to end:
./01-serverless-etl/run.sh
./03-warm-pool-low-latency/run.sh

# BDS use cases — copy and submit the job on a cluster node, then verify HDFS:
./02-hadoop-cluster-analytics/run.sh
./04-secure-ha-production/run.sh
```

All four entry points run end to end. **01 and 03** wait for the Data Flow run
to reach `SUCCEEDED` and verify Object Storage output. **02 and 04** use the
operator's dedicated BDS identity to execute `spark-submit` on a BDS node, wait
for YARN, and read the resulting report from HDFS.

If a use case isn't supported by your deployment, the script says so and names
the form field to flip. For example, running a BDS use case on a Data-Flow-only
stack prints:

```
This use case can't run on the current deployment.
  Big Data Service is not deployed. Set 'Deploy Big Data Service (Hadoop)' = on.
```

## What to expect

### 01 — Serverless ETL
`run.sh` uploads `customers_etl.py` + `sample_customers.csv`, creates/reuses the
`<prefix>-customers-etl` application, and submits a run (matched to the warm-pool
shape when a pool exists). It repairs stale pool attachments, waits for the run,
and verifies the output prefix before returning.

- The run reaches **`SUCCEEDED`**; timing depends on region capacity and whether
  a pool is attached. Poll with
  `oci data-flow run get --run-id <id> --query 'data."lifecycle-state"'`.
- The 10-row sample is cleaned to **8 customer rows** (one null-email row dropped,
  one duplicate email de-duped) and written as **Parquet partitioned by country**
  (GB/US/FR/FI) to the warehouse bucket:
  ```
  oci os object list -bn <prefix>-dataflow-warehouse --prefix customers_clean/
  # customers_clean/country=GB/part-*.snappy.parquet, .../country=US/... etc.
  ```
- Driver output (`Read 10 raw rows`, `Writing 8 cleaned customer rows`) is in the
  logs bucket and in the Data Flow console under the run's **Logs**.

### 02 — Hadoop cluster analytics
`run.sh` resolves the active cluster, copies the sample to its utility node,
submits `sales_report.py` to YARN, and prints the verified HDFS CSV report. On a
secure cluster it uses BDS's built-in `ambari-qa` smoke-test principal/keytab;
the `hdfs` service user is deliberately banned by YARN and must not submit jobs.

If the cluster is still provisioning, it prints the cluster list with each
cluster's state instead (wait for `ACTIVE`).

### 03 — Warm-pool low latency
`run.sh` behaves like 01 but the app runs on the **warm pool**.

- Starts a stopped pool if necessary, repairs applications still attached to a
  replaced/deleted pool, and submits `<prefix>-hourly-aggregate`.
- The run reaches **`SUCCEEDED`**; compare repeated runs to measure the pool's
  provisioning-latency reduction in your region.
- Output is a **Parquet rollup** at `hourly_rollup/` — `event_count` +
  `unique_users` per hour per `event_type`.
- Submit it **back-to-back** and compare wall time with Spark execution time:
  ```
  oci data-flow run list --compartment-id <compartment> \
    --query 'data[].{name:"display-name",created:"time-created",updated:"time-updated",spark_ms:"run-duration-in-milliseconds"}'
  ```

### 04 — Secure HA production
`run.sh` first invokes `check.sh`, which requires **secure + HA**, verifies every
node is `ACTIVE`, obtains a Kerberos ticket with the supported smoke-test
principal, and confirms bootstrap tuning under the active Spark config path.
It then runs the same real YARN/HDFS analytics job as use case 02.

### When a run fails
For 01/03, if a run shows `FAILED`, the driver log in the **logs bucket** has the
Spark stack trace:
```
oci os object list -bn <prefix>-dataflow-logs --query 'data[].name' --output table
```

## Architecture

```
   you ──ssh──► OCI Bastion ──► Operator VM (private subnet, instance principal)
                                   │  cd use-cases; ./run.sh
                                   ▼
            ┌──────────────────────────────────────────────┐
            │ Data Flow (serverless Spark)  ◄── 01, 03      │
            │ Big Data Service (Hadoop)     ◄── 02, 04      │
            │ Object Storage (scripts / logs / warehouse)   │
            └──────────────────────────────────────────────┘
```

> **Cost reminder.** The operator VM, BDS nodes, and a Data Flow warm pool all
> bill continuously while they exist. `terraform destroy` (or destroy the Stack)
> when you're done. Plain Data Flow runs bill only for the seconds they execute.

## Tear down

Running the use cases leaves state Terraform doesn't track — objects in the
buckets (uploaded scripts, run logs, output) and a running warm pool — and a
bucket can't be deleted while non-empty, nor a pool while running. The stack
tries to clean this up automatically on `destroy` (see `cleanup.tf`), but that
relies on the destroy host having OCI CLI auth (not guaranteed on a Resource
Manager runner). The reliable path is to empty things first **from the operator**
(it always has instance-principal auth):

```bash
./use-cases/cleanup.sh     # stops the pool, empties the buckets
```

Then run `terraform destroy` / destroy the Stack.
