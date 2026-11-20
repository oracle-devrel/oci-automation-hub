# Secure Hadoop & Spark on OKE

A security-hardened, **one-click** Terraform stack that deploys Apache Hadoop
(HDFS) and Apache Spark on **Oracle Kubernetes Engine (OKE)**. Think of it as an
open-source, self-hosted alternative to Big Data Service / Data Flow: fill in a
form, apply **once**, and you get a locked-down cluster with the platform you
selected installed and **ready for your jobs**.

Storage is configurable — deploy **HDFS**, **OCI Object Storage**, or **both**.
Spark runs natively on Kubernetes via the Spark Operator (no YARN). What you run
on the platform (your Spark/Hadoop jobs) is yours; this stack delivers the
turn-key, secured infrastructure underneath.

The OKE cluster + node pool are provisioned through the official
[`terraform-oci-oke`](https://registry.terraform.io/modules/oracle-terraform-modules/oke/oci)
module; the in-cluster platform is provisioned with the `kubernetes` / `helm`
providers in the **same apply**.

---

## One apply, one stack

Everything — VCN, OKE cluster, node pool, OCI Bastion, IAM/Workload Identity,
the Object Storage bucket, **and** the in-cluster platform (Kerberos KDC, HDFS,
the Spark Operator, RBAC, NetworkPolicies) — lives in a single Terraform state
and deploys in a single `apply`.

### How the platform gets installed (operator bootstrap)

The Terraform runner (your laptop, or the Resource Manager job) has **no network
path to the cluster API** — that's by design: the API endpoint is private/locked.
So the platform is **not** installed with the `kubernetes`/`helm` Terraform
providers. Instead:

1. The `terraform-oci-oke` module creates a small **private operator VM inside
   the VCN**, with a private-endpoint kubeconfig and `kubectl`/`helm` installed.
   Its instance principal is granted `manage clusters` (→ cluster-admin) by an
   IAM policy the module creates.
2. The platform is rendered by Terraform as Kubernetes manifests + a helm
   command (`platform.tf`) and handed to the operator as **cloud-init**.
3. On boot, the operator waits for a Ready node, then `kubectl apply`s the
   manifests and `helm install`s the Spark Operator — **from inside the VCN**.

Because the install runs from the operator, the apply never needs to reach the
API. This works in **Resource Manager** with a fully private cluster, no RM
private endpoint required.

> **Asynchronous:** `apply` finishes once the operator VM exists; the platform
> comes up a few minutes later as cloud-init runs. Verify from the operator (see
> Deploy). Updating the platform later means re-running the bootstrap (changing
> the operator's cloud-init), not a plain `apply` of in-cluster resources.

---

## Storage — configurable

Two independent toggles (deploy either, or both):

- **`deploy_hdfs`** — Kerberos-secured HDFS running on the cluster as
  StatefulSets with block-volume PVCs, plus an in-cluster MIT KDC. Best for
  HDFS-native workloads and data locality.
- **`deploy_object_storage`** — a private OCI Object Storage bucket as the data
  lake, reached from Spark via `oci://…` with Workload Identity. Best for
  decoupled, elastic storage.

`deploy_spark` installs the Spark Operator. Users pick per deployment; Spark is
wired to whichever backends are present.

---

## Security model

| Control | How |
|---|---|
| **No public worker nodes** | Worker nodes run in a private subnet with no public IPs. |
| **Locked API endpoint** | The Kubernetes API endpoint is restricted by NSG to `admin_cidr`. |
| **Bastion-only host access** | Node SSH (and `kubectl` to a private endpoint) go through the managed OCI Bastion, restricted to `admin_cidr`. |
| **No static cloud credentials** | OKE **Workload Identity** (enhanced cluster) gives Spark pods short-lived, scoped OCI tokens for Object Storage — no keys. |
| **Kerberos** | When HDFS is deployed, an in-cluster KDC secures HDFS RPC (privacy), data transfer and web UIs; block-access tokens enabled. |
| **No exposed big-data services** | Every Service is `ClusterIP`/headless — **never** LoadBalancer/NodePort. Spark runs on Kubernetes, **not** YARN and **not** a Spark standalone master, so the classic unauth-RCE vectors (YARN ResourceManager REST; Spark master REST :6066) don't exist. |
| **Egress lockdown** | A default-deny-egress NetworkPolicy + allowlist (DNS, in-cluster/VCN, OKE identity metadata, region-specific OCI Service Network :443) blocks the internet egress a compromised pod would use for C2 / exfiltration / crypto-mining. |
| **Pod Security / RBAC** | Namespace Pod Security Admission (`baseline` enforced); Spark uses a tightly-scoped Role, not cluster-admin. |
| **Encryption** | etcd encrypted at rest by OKE; Object Storage encrypted at rest; in-cluster TLS / Kerberos privacy. |
| **Hardened images** | `image_source = ocir` lets you run your own scanned/signed images instead of upstream public ones. |

`admin_cidr = 0.0.0.0/0` is rejected by a validation rule.

> ### NetworkPolicy enforcement
> The flannel CNI does **not** enforce NetworkPolicies on its own. The
> ingress/egress policies (rendered in `platform.tf`) are inert until a policy
> engine is installed. Install **Calico in policy-only mode** as a one-time
> follow-up so they take effect (it can be added to the operator's bootstrap
> script). Not bundled by default because the Calico operator + Installation CR
> is a CRD-then-CR pattern that is brittle on a brand-new cluster.

---

## Deploy

### Resource Manager (one-click)
```bash
zip -r hadoop-spark-oke.zip . -x '.git/*' '.terraform/*' '*.tfstate*'
```
Console → **Resource Manager → Stacks → Create Stack → My configuration**,
upload the zip, fill in the form (**`admin_cidr` is required**), Plan, Apply.
The operator installs the platform from inside the VCN, so no RM private
endpoint is needed and the cluster can stay fully private.

### Terraform CLI
```bash
cp example.tfvars.template my.tfvars   # edit - admin_cidr is required
terraform init
terraform plan  -var-file=my.tfvars
terraform apply -var-file=my.tfvars    # one apply does everything
```

### After apply (verify the platform)
The platform comes up a few minutes after apply, installed by the operator. To
watch/verify, connect to the operator with the one-command helper (the
`operator_access` output prints it filled in) — it creates the Bastion session,
waits, and SSHes you in:
```bash
./scripts/connect-operator.sh -b <bastion_ocid> -i <operator_private_ip>
```
Then, on the operator:
```bash
cloud-init status --wait                 # bootstrap finished
kubectl -n <cluster_name> get pods       # KDC, NameNode, DataNodes, Spark Operator

# Smoke-test Spark-on-Kubernetes (spark_smoke_test output):
kubectl -n <cluster_name> get configmap spark-examples \
  -o go-template='{{index .data "sparkpi.yaml"}}' | kubectl apply -f -
```
The operator already has a working kubeconfig (instance principal). To run
kubectl from your own machine instead, open a Bastion port-forward to the
private API endpoint and fetch a kubeconfig with `--kube-endpoint PRIVATE_ENDPOINT`.

**Prove it works:** ready-to-run demos (one per profile — Spark-only,
HDFS+Spark, Object-Storage+Spark) generate data and print evidence. See
[use-cases/](use-cases/). They are written to the operator at
`/home/opc/use-cases` on first boot:
```bash
cd ~/use-cases && ./01-spark-only/run.sh
```

The operator bootstrap writes the deployed namespace, region, and compartment
to `deployment.env`; set `NS=...` only when intentionally overriding it.

---

## Repository layout

```
provider.tf    terraform / OCI providers (oci + home-region alias)
variables.tf   all input variables
locals.tf      derived values
data.tf        ADs, services, region subscriptions (home region)
network.tf     VCN, subnets (incl. private internal-LB subnet), gateways, NSGs
oke.tf         OKE cluster + node pool + operator (terraform-oci-oke module)
bastion.tf     OCI Bastion service
iam.tf         Workload Identity dynamic group + policy (home region)
storage.tf     Object Storage bucket
secrets.tf     Kerberos passwords (random_password, when deploy_hdfs)
platform.tf    in-cluster manifests (KDC/HDFS/RBAC/NetworkPolicies/Spark) +
               the operator bootstrap that applies them and writes the demos
scripts/       KDC / keytab / HDFS entrypoint scripts (embedded as ConfigMaps)
use-cases/     runnable demos proving each profile (Spark / HDFS / Object Storage)
outputs.tf     cluster OCID, operator access, platform outputs
schema.yaml    Resource Manager form
```

## Honest status

The stack is structurally validated (`terraform validate`). The in-cluster
platform — HDFS StatefulSets, the KDC, Kerberos handshakes, the Spark Operator,
and the operator cloud-init bootstrap — is genuinely complex and can only be
fully proven on a live cluster; expect to iterate during the first real
deployment. Before relying on it, validate (a) a clean first `apply` and
`destroy`, (b) that the operator's cloud-init applied the platform
(`cloud-init status` + `kubectl get pods` on the operator), and (c) install
Calico so the NetworkPolicies are actually enforced.
