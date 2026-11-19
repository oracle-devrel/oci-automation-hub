# Use case 02 — Analytics on a managed Hadoop cluster

**Goal:** run a Spark job with `spark-submit` against YARN on a real Hadoop
cluster — reading from and writing to HDFS. The classic "I want a cluster I can
log into" experience, fully managed by OCI Big Data Service (BDS).

Use this when you need long-running services (Hive metastore, HBase, Trino), an
interactive cluster, or workloads that don't fit the serverless Data Flow model.

## Requires in the Resource Manager form

| Field | Value |
|-------|-------|
| Deploy Big Data Service (Hadoop) | **on** |
| Cluster profile | HADOOP_EXTENDED (default) |
| Deploy operator VM behind OCI Bastion | on |
| SSH public key | your key for reaching the operator through Bastion |

> BDS provisioning takes **~30 minutes** and the worker nodes bill continuously.
> Destroy the stack when you're done.

## Run it (from the operator VM)

`spark-submit` has to run **on a BDS node**, but `submit.sh` itself runs on the
operator. Terraform installs a dedicated operator-to-BDS key at
`~/.ssh/bds_operator`, so the use case does not depend on your laptop or SSH
agent forwarding:

```bash
cd use-cases/02-hadoop-cluster-analytics
./run.sh
```

Stacks created before the dedicated key was introduced can set `BDS_SSH_KEY`
to an authorized private key on the operator. Forwarded agents are accepted
only as a backward-compatible fallback.

`run.sh` self-checks BDS, resolves the cluster's utility/master IPs, copies the
job and sample data, runs `spark-submit`, waits for YARN to finish, and reads the
CSV report back from HDFS. It runs:

```bash
spark-submit --master yarn --deploy-mode cluster \
  --num-executors 3 --executor-cores 4 --executor-memory 8g \
  /tmp/sales_report.py \
  hdfs:///user/<submit-user>/sales/sales.csv \
  hdfs:///user/<submit-user>/sales_report
```

### Secure (Kerberos) clusters

The commands above are for a **non-secure** cluster (this use case's intended
shape). If you deployed with **Secure cluster = on** (Kerberos + Ranger — the
[use case 04](../04-secure-ha-production/) shape), HDFS/YARN reject any command
without a Kerberos ticket:

```
org.apache.hadoop.security.AccessControlException:
  Client cannot authenticate via:[TOKEN, KERBEROS]
```

`run.sh` detects this and uses the built-in `ambari-qa` smoke-test OS user and
`smokeuser.headless.keytab`. This is important: BDS explicitly lists `hdfs`,
`yarn`, and `mapred` as banned YARN submission users, so running the application
as `hdfs` fails before the ApplicationMaster starts.

Web UIs (Ambari, Hue, Spark History, YARN RM on port 8088) are served from the
utility node — tunnel to them over SSH from the operator.

## What the job demonstrates

`sales_report.py`:

- Reads a sales CSV from **HDFS** (the on-cluster story).
- Computes revenue by region and product category, plus each category's share of
  total revenue using a window function.
- Writes a single coalesced CSV report back to HDFS.

It runs on YARN in cluster mode, so the driver and executors schedule across your
worker nodes — scale `bds_worker_count` (or add compute-only workers, see
[use case 04](../04-secure-ha-production/)) and the same job spreads wider.

### Reading Object Storage from the cluster

BDS reads `oci://` paths directly (HDFS connector + resource principal), so you
can keep data in Object Storage and treat the cluster as pure compute — swap the
`hdfs:///...` arguments for `oci://bucket@namespace/...`. `submit.sh` prints the
scripts-bucket URI to make that easy.

## If it can't run

If BDS isn't deployed, `run.sh` stops with:

```
This use case can't run on the current deployment.
  Big Data Service is not deployed. Set 'Deploy Big Data Service (Hadoop)' = on.
```
