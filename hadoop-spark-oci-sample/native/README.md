# Spark + Hadoop on OCI — Terraform stack

A configurable Terraform deployment that stands up a complete Spark + Hadoop
platform on Oracle Cloud Infrastructure:

- **OCI Big Data Service** — managed Hadoop cluster (HDFS, YARN, Spark, Hive, …)
- **OCI Data Flow** — serverless Spark applications, optional warm pool
- **Object Storage** — buckets for Spark scripts, logs and warehouse output
- **VCN** — created on demand, or you can reuse an existing one
- **IAM** — dynamic group + policy so Data Flow runs can talk to your buckets

The stack runs from the Terraform CLI **and** from the OCI Resource Manager
(`schema.yaml` ships in the repo).

---

## Repository layout

```
.
├── provider.tf              # OCI + random providers
├── variables.tf             # All input variables
├── locals.tf                # Derived values
├── network.tf               # VCN, subnets, gateways, security lists
├── object_storage.tf        # Buckets for Data Flow
├── iam.tf                   # Dynamic group + policies for Data Flow runs
├── bds.tf                   # Big Data Service (Hadoop) cluster
├── dataflow.tf              # Data Flow applications + warm pool
├── operator.tf              # Operator VM + OCI Bastion + instance-principal IAM
├── outputs.tf
├── schema.yaml              # Resource Manager form schema
├── terraform.tfvars.example # Three showcase profiles
├── templates/
│   └── operator_init.sh.tftpl  # Operator cloud-init (tooling + deployment.env)
├── examples/
│   ├── pi.py                # Bundled sample PySpark job
│   ├── demo.sql             # Bundled sample Spark SQL job
│   └── bootstrap.sh         # Example BDS bootstrap script
└── use-cases/               # End-to-end scenario walkthroughs (see below)
    └── lib.sh               # Capability-check helpers sourced by the run scripts
```

---

## Example use cases

The [`use-cases/`](use-cases/) folder contains self-contained, end-to-end
walkthroughs that show what the stack can do. The intended flow is to **deploy
via Resource Manager with the operator VM enabled**, open an **OCI Bastion**
session into the operator, and run the scripts there — each script self-checks
what the stack actually deployed and tells you which form field to change if a
use case isn't supported. Start with [`use-cases/README.md`](use-cases/README.md).

| Use case | Showcases |
|----------|-----------|
| [01 — Serverless ETL](use-cases/01-serverless-etl/) | Cheapest Spark on OCI: CSV → Parquet via Data Flow, no cluster |
| [02 — Hadoop cluster analytics](use-cases/02-hadoop-cluster-analytics/) | `spark-submit` on YARN + HDFS on a managed BDS cluster |
| [03 — Warm-pool low latency](use-cases/03-warm-pool-low-latency/) | Repeated/scheduled jobs with reduced provisioning latency via a warm pool |
| [04 — Secure HA production](use-cases/04-secure-ha-production/) | Kerberos + Ranger, HA, elastic compute-only workers, bootstrap tuning |

---

## Operator VM + OCI Bastion

Set **`deploy_operator = true`** (form: *Deploy operator VM behind OCI Bastion*)
to add a small jump/control host in the private subnet, reachable only through
the **OCI Bastion** service — no public IP, no internet-facing SSH. It is the
recommended way to drive the use cases.

What it gives you:

- The use-case scripts staged on the box — Terraform uploads `use-cases/` to the
  scripts bucket, and the operator pulls them at boot with instance-principal
  auth — plus a `deployment.env` descriptor of what the stack deployed (so the
  scripts can precheck capabilities). This works from Resource Manager because
  the operator self-pulls; nothing is pushed from the apply host.
- **Instance-principal auth** — a dynamic group + policy let the VM submit Data
  Flow runs and use Object Storage with no API keys on the host.
- A purpose-specific SSH key for operator-to-BDS access, so the Hadoop use cases
  run entirely from the operator without forwarding your workstation agent.

The generated operator-to-BDS private key is sensitive Terraform state. OCI
Resource Manager protects managed state at rest; if you run Terraform locally,
secure the state backend accordingly.
- A ready-made connect command in the `operator_bastion_session_hint` output.

Connect:

```bash
terraform output -raw operator_bastion_session_hint   # prints the session command
# run it, wait for SUCCEEDED, then SSH via the bastion
```

If you can't create tenancy-level IAM (`create_iam_resources = false`),
pre-create the operator's dynamic group and policy out of band:

- Dynamic group matching rule: `ALL {instance.id = '<operator instance OCID>'}`
- Policy statements (in the deployment compartment):
  - `Allow dynamic-group <dg> to manage dataflow-family in compartment id <c>`
  - `Allow dynamic-group <dg> to read buckets in compartment id <c>`
  - `Allow dynamic-group <dg> to manage objects in compartment id <c>`
  - `Allow dynamic-group <dg> to read objectstorage-namespaces in tenancy`

---

## Running from the Terraform CLI

### Prerequisites

- Terraform `>= 1.3`
- An OCI API key configured (`~/.oci/config` or env vars)
- IAM rights to create VCN, BDS, Data Flow, Object Storage **and** to create
  a tenancy-level dynamic group + policy (or pre-create them out of band)

### Steps

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — set tenancy_ocid, compartment_ocid, region,
# ssh_public_key, bds_cluster_admin_password

terraform init
terraform plan
terraform apply
```

To tear it all down:

```bash
terraform destroy
```

---

## Running from OCI Resource Manager

1. Zip the repo (exclude `.terraform/`, `*.tfstate*`):

   ```bash
   zip -r spark-hadoop-stack.zip . \
     -x '.git/*' -x '.terraform/*' -x '*.tfstate*' -x 'terraform.tfvars'
   ```

2. In the OCI Console go to **Developer Services → Resource Manager → Stacks
   → Create stack**.
3. Source: **My configuration → .zip file**, upload `spark-hadoop-stack.zip`.
4. Resource Manager reads `schema.yaml` and renders the input form. Fill it
   in.
5. Run **Plan**, then **Apply**.

`schema.yaml` hides the CLI-only auth variables, groups the inputs into
logical panels (Networking, BDS Master / Utility / Workers, Data Flow, Warm
Pool …), and conditionally shows the "existing VCN/subnet" pickers only when
**Create VCN** is unticked.

---

## What gets deployed

### Networking

| `create_vcn` | Result |
| --- | --- |
| `true` (default) | A new VCN (`10.0.0.0/16` by default) with a public + private subnet, Internet Gateway, NAT Gateway, Service Gateway, route tables and security lists. |
| `false` | The stack reuses the VCN + subnets whose OCIDs you supply (`existing_vcn_id`, `existing_private_subnet_id`, `existing_public_subnet_id`). Nothing network-level is created or modified. |

### Big Data Service (Hadoop)

Toggled by `deploy_bds`. Configurable knobs:

- **Cluster version** — `ODH0.9` … `ODH2.1`
- **Cluster profile** — `HADOOP`, `HADOOP_EXTENDED`, `SPARK`, `HIVE`,
  `HBASE`, `TRINO`, `KAFKA`, `DATAFLOW`, `DATA_SCIENCE`, `AIRFLOW`
- **High availability** — 1+1 or 2+2 master + utility nodes
- **Security** — Kerberos + Ranger toggle (`bds_is_secure`)
- **Per node-group sizing** — shape, OCPUs, memory, block volume, count for
  master / utility / worker / compute-only worker pools
- **Bootstrap script** — `bds_bootstrap_script_url` points at an Object
  Storage URL; BDS runs the script on every node at creation time. Use it
  to push custom `core-site.xml`, `hdfs-site.xml`, `yarn-site.xml`,
  `spark-defaults.conf`, install extra packages, drop keytabs, etc.
  `examples/bootstrap.sh` is a starting template.

### Data Flow (Spark)

Toggled by `deploy_dataflow`. The list `dataflow_applications` accepts any
number of applications — each one is a separate showcase of Spark on
OCI. Each entry exposes:

- `language` — `PYTHON` / `JAVA` / `SCALA` / `SQL`
- `spark_version` — e.g. `3.5.0`, `3.2.1`
- `file_uri` — pointer to the entry-point script/jar in Object Storage.
  If left empty, the stack falls back to the bundled sample for the
  language (`examples/pi.py` for PYTHON, `examples/demo.sql` for SQL),
  which it uploads into the scripts bucket for you.
- `driver_shape`, `driver_ocpus`, `driver_memory_gbs`
- `executor_shape`, `executor_ocpus`, `executor_memory_gbs`, `num_executors`
- `configuration` — a map of Spark properties (e.g. `spark.sql.shuffle.partitions`,
  `spark.dynamicAllocation.enabled`, …). This is the per-application Spark
  config knob.

An optional **warm pool** (`dataflow_create_pool`) reserves Data Flow capacity
to reduce and stabilize application startup latency.

### Object Storage

Three buckets are created (each independently toggle-able):

- `<prefix>-dataflow-scripts` — holds Spark entry points
- `<prefix>-dataflow-logs` — Data Flow stdout/stderr + Spark event logs
- `<prefix>-dataflow-warehouse` — Spark SQL output (Parquet/etc.)

### IAM

Toggled by `create_iam_resources` (default `true`). When enabled the stack
creates:

- **For Data Flow** (`deploy_dataflow`): a **dynamic group** matching
  `resource.type='dataflowrun'` in the target compartment, plus a **policy**
  granting that group read/write on Object Storage in the compartment.
- **For BDS** (`deploy_bds`): a **policy** granting the `bdsprod` service
  principal access to the VCN/subnet so it can attach cluster nodes. Without
  this, cluster creation fails with *"not enough permissions to access subnet
  or vcn details"*. The policy is scoped to `compartment_ocid` by default; set
  `bds_network_compartment_ocid` when reusing an existing VCN/subnet that lives
  in a different compartment.

Dynamic groups and policies live at the tenancy root, so the caller needs
IAM admin rights on the tenancy. If you cannot grant those, set
`create_iam_resources = false` and pre-create the resources out of band:

```text
# Data Flow dynamic group — name it whatever you like
Matching rule:
  ALL {resource.type='dataflowrun', resource.compartment.id='<COMPARTMENT_OCID>'}

# Data Flow policy — attach in the tenancy
Allow dynamic-group <DG_NAME> to read buckets in compartment id <COMPARTMENT_OCID>
Allow dynamic-group <DG_NAME> to manage objects in compartment id <COMPARTMENT_OCID>
Allow dynamic-group <DG_NAME> to read objectstorage-namespaces in tenancy

# BDS network policy — attach where the VCN/subnet lives (<NETWORK_COMPARTMENT_OCID>)
Allow service bdsprod to {VNIC_READ, VNIC_ATTACH, VNIC_DETACH, VNIC_CREATE, VNIC_DELETE, VNIC_ATTACHMENT_READ, SUBNET_READ, VCN_READ, SUBNET_ATTACH, SUBNET_DETACH, INSTANCE_ATTACH_SECONDARY_VNIC, INSTANCE_DETACH_SECONDARY_VNIC} in compartment id <NETWORK_COMPARTMENT_OCID>
```

---

## Showcase profiles

`terraform.tfvars.example` includes three commented-out profiles:

| Profile | Use case |
| --- | --- |
| **Minimal** | Data Flow only, no Hadoop cluster — quick Spark try-out. |
| **Standard** | Small Hadoop cluster + a couple of Spark apps + warm pool. Two Data Flow apps: one with default Spark config, one with adaptive query execution + Kryo + dynamic allocation. |
| **Production-ish** | HA Hadoop with compute-only workers, secure cluster, custom bootstrap script, larger warm pool. |

Mix and match: any field can be overridden independently.

---

## Customising Hadoop and Spark

| Knob | Where |
| --- | --- |
| Per-application Spark properties (Data Flow) | `dataflow_applications[*].configuration` map |
| Cluster-wide Hadoop / Spark config (BDS) | `bds_bootstrap_script_url` — edits `core-site.xml`, `hdfs-site.xml`, `yarn-site.xml`, `spark-defaults.conf` directly on the nodes. See `examples/bootstrap.sh`. |
| Per-node sizing (BDS) | `bds_*_shape`, `bds_*_ocpus`, `bds_*_memory_gbs`, `bds_*_block_volume_gbs` |
| Compute / storage separation | Add compute-only workers via `bds_compute_only_worker_count` |
| Cluster role | `bds_cluster_profile` (full Hadoop vs Spark-only vs Hive vs HBase vs Trino vs …) |
| Kerberos / Ranger | `bds_is_secure` |
| Warm Spark executors | `dataflow_create_pool`, `dataflow_pool_*` |

---

## Outputs

After `apply`:

- `bds_cluster_id`, `bds_master_node_ips`, `bds_utility_node_ips` —
  SSH into the utility node to reach Ambari / Cloudera Manager / Hue.
- `dataflow_application_ids` — submit runs with
  `oci data-flow run create --application-id <id>` or the console.
- `scripts_bucket_uri`, `logs_bucket_name`, `warehouse_bucket_name` —
  upload your own scripts and consume logs / results.

---

## Notes

- Some IAM resources (`oci_identity_dynamic_group`, `oci_identity_policy`)
  are created at the **tenancy** level. The principal running this stack
  needs `manage dynamic-groups` + `manage policies` in the tenancy.
- BDS provisioning takes ~30 minutes.
- Data Flow application creation is fast; cost is incurred only when a run
  is submitted (or when a warm pool is running).
