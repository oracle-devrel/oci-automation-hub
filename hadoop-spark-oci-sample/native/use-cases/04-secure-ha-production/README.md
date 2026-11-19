# Use case 04 — Secure, highly-available production cluster

**Goal:** the enterprise shape of the stack — a **Kerberized, Ranger-secured,
highly-available** Hadoop cluster with **elastic compute-only workers**,
cluster-wide tuning applied at provisioning via a **bootstrap script**, and a
Data Flow warm pool alongside for serverless jobs.

The most expensive profile — a reference for the knobs. Size it down for a real
budget.

## Requires in the Resource Manager form

| Field | Value |
|-------|-------|
| Deploy Big Data Service (Hadoop) | **on** |
| High availability (2 master + 2 utility) | **on** |
| Secure cluster (Kerberos + Ranger) | **on** |
| Compute-only worker count | e.g. 3 |
| Bootstrap script URL (Object Storage) | URL of `bootstrap.sh` (see below) |
| Deploy operator VM behind OCI Bastion | on |

> HA and Secure must match (the stack enforces it). BDS provisioning takes ~30
> min and this is a large, always-billing footprint — destroy it when done.

## Step 0 — upload the bootstrap script before deploying

BDS reads the bootstrap script from Object Storage **at cluster-creation time**,
so it must exist before you apply. Upload `bootstrap.sh` to a bucket you control
and put its URL in the **Bootstrap script URL** field:

```bash
NS=$(oci os ns get --query data --raw-output)
oci os bucket create --compartment-id <compartment-ocid> --name bootstrap-scripts || true
oci os object put -bn bootstrap-scripts --file bootstrap.sh --force
echo "https://objectstorage.<region>.oraclecloud.com/n/$NS/b/bootstrap-scripts/o/bootstrap.sh"
```

## Verify and use it (from the operator VM)

Connect to the operator through OCI Bastion. Terraform installs a dedicated
operator-to-BDS key, so no SSH agent forwarding from your laptop is required.
Then:

```bash
cd use-cases/04-secure-ha-production
./run.sh
```

`run.sh` requires secure + HA, verifies every node is `ACTIVE`, checks Kerberos
with the BDS smoke-test principal, confirms the bootstrap marker on a master,
then submits and verifies the sample YARN/HDFS analytics job.

Confirm the bootstrap tuning landed:

```bash
ssh opc@<master-ip> 'grep -A3 "stack bootstrap" /etc/spark/conf/spark-defaults.conf'
```

## What this demonstrates

| Capability | Form field | Why it matters |
|------------|-----------|----------------|
| **High availability** | High availability → 2+2 masters/utility | No single point of failure for NameNode/ResourceManager/services |
| **Security** | Secure cluster → Kerberos + Ranger | Authenticated users, fine-grained authorization, audit |
| **Elastic compute** | Compute-only worker count | Add Spark/YARN horsepower without growing HDFS |
| **Cluster-wide config** | Bootstrap script URL | Bake in Spark/YARN tuning, packages, keytabs at provisioning |
| **Hybrid serverless** | Data Flow warm pool | Serverless Spark next to the cluster for spiky/ad-hoc jobs |

## Sizing it down

Keep High availability + Secure on (they must stay paired), but shrink workers
(3 × 8 OCPU / 128 GB), set compute-only workers to 0, and lower the pool max.

## If it can't run

If BDS isn't deployed, `run.sh` stops and names **Deploy Big Data Service**. If
the cluster is not both secure and highly available, validation fails before a
job is submitted.
