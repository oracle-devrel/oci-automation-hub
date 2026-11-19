# Examples — proving the three deployment profiles

Production-shaped demos that **generate data and exercise the deployed Hadoop /
Spark platform**, printing clear `PROOF:` / `RESULT:` evidence that each
configuration works:

| Demo | Profile | What it proves |
|------|---------|----------------|
| [`01-spark-only`](01-spark-only/) | `deploy_spark` | Spark-on-Kubernetes: driver + executors generate data and run a distributed aggregation — no external storage. |
| [`02-hdfs-spark`](02-hdfs-spark/) | `deploy_hdfs` + `deploy_spark` | Kerberos auth → write/read data in secured HDFS, then Spark reads HDFS with a keytab, aggregates, writes back. |
| [`03-objstore-spark`](03-objstore-spark/) | `deploy_object_storage` + `deploy_spark` | Spark round-trips data through an OCI Object Storage bucket over `oci://` using OKE Workload Identity (no keys). |

## Where to run them

Run from the **operator host** — it sits inside the VCN with `kubectl`, `helm`
and a working kubeconfig. The stack **writes these demos to the operator at
`/home/opc/use-cases`** on first boot (no keys, no copying). Reach the operator
through the OCI Bastion with the one-command helper (the `operator_access`
output prints it filled in):

```bash
./scripts/connect-operator.sh -b <bastion_ocid> -i <operator_private_ip>
```

Then, on the operator:

```bash
cd ~/use-cases
./01-spark-only/run.sh
```

The operator writes the deployed namespace, region, and compartment to
`deployment.env`, which every script loads automatically. You can still set
`NS=...` explicitly to target another namespace.

(To iterate locally instead, the same files live in this repo's `use-cases/`.)

Each script is self-contained: it submits a `SparkApplication` (via the Spark
Operator), waits for it to finish, and prints the proof from the driver log. A
non-zero exit means a step failed (the script prints `[FAIL] …` and the driver
log).

## Configuration (environment variables)

| Var | Default | Meaning |
|-----|---------|---------|
| `NS` | deployed `cluster_name` | Namespace override. Normally loaded from `deployment.env`. |
| `SPARK_IMAGE` | `docker.io/apache/spark:3.5.3` | Image for the Spark jobs (fully-qualified; must include PySpark). |
| `SPARK_VERSION` | `3.5.3` | Spark version label. |
| `TIMEOUT` | `900` | Seconds to wait for a job. |
| `OS_NAMESPACE`, `REGION`, `CONNECTOR_VERSION`, `AUTHENTICATOR` | — | Demo 3 only (Object Storage). |

## Honest notes

- **PySpark image:** the demos run Python jobs, so `SPARK_IMAGE` must include
  PySpark. `apache/spark:3.5.x` does; if yours doesn't, set `SPARK_IMAGE` to a
  Python-enabled Spark image (or your hardened OCIR image).
- **Demo 2 (HDFS+Spark):** Part A (direct HDFS via the NameNode pod) is the
  rock-solid proof of Kerberos + HDFS. Part B wires a keytab into the Spark pods
  to read secured HDFS — a real production pattern, but Kerberos-on-Spark is
  fiddly; if Part B needs tuning for your image, Part A still proves the data
  path.
- **Demo 3 (Object Storage):** Spark reaches `oci://` via the **oci-hdfs-connector**
  pulled with `--packages` and authenticated by OKE Workload Identity. The
  connector **version** (`CONNECTOR_VERSION`) and **authenticator class**
  (`AUTHENTICATOR`) are version-sensitive — adjust them to match your connector.
  `--packages` downloads from Maven Central, which needs internet egress
  (available via the NAT gateway).
- **NetworkPolicy / egress:** the namespace ships a default-deny-egress policy,
  but it is **inert until Calico is installed** (flannel doesn't enforce it). If
  you *have* installed Calico, allow Maven egress for Demo 3 or pre-bake the
  connector into a custom image.
- These are demos: cleanup commands are printed at the end of each run.
