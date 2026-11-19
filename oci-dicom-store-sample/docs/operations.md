# Operations runbook

## Day-two health checks

Run:

```bash
scripts/verify.sh
```

From the management host, run the private-path checks:

```bash
scripts/ssh-bastion.sh sudo /usr/local/sbin/dicom-status
```

Then review:

- API Gateway access and execution logs in the generated log group
- `oci_apigateway` `HttpResponses`, `BackendHttpResponses`, and latency metrics
- OKE node/pod readiness, including at least two ready Orthanc pods on two
  workers, and the `dicom-gateway` Service/NLB state
- PostgreSQL DB-system state, at least two active nodes, and backup history
- Object Storage object count, size, and version growth
- OKE managed node-pool lifecycle and Kubernetes deployment rollout state

Supplying an existing Notifications topic enables the API Gateway 5xx alarm.
Create OCI Health Checks from an approved private or public vantage point if
you need independent liveness monitoring. Orthanc endpoints require
authentication, so do not create an unauthenticated health route containing
patient data.

## Bastion operations

The Oracle Linux bastion is the only public SSH target. Its NSG admits TCP/22
only from `bastion_allowed_ssh_cidrs` (or `allowed_client_cidrs` when the
dedicated list is empty). Password login, root login, agent forwarding, and
remote forwarding are disabled. Local forwarding remains enabled so an
authorized operator can create a loopback-only tunnel when needed.

Reapply the idempotent host configuration after an operator-tool update:

```bash
export BASTION_SSH_PRIVATE_KEY_FILE=/absolute/path/to/id_rsa
scripts/configure-bastion.sh
```

Useful commands on the host:

```bash
sudo /usr/local/sbin/dicom-status
sudo /usr/local/sbin/dicom-env
sudo /usr/local/sbin/dicom-psql
sudo journalctl -u sshd
kubectl get pods -A
```

The root-only stack file contains Orthanc and PostgreSQL credentials. Rotate
credentials if a bastion administrator who could read that file loses access,
then rerun Ansible. Do not place OCI API signing keys on the host. Prefer a
short-lived security-token session if OCI CLI access is required.

## Scaling

`orthanc_replicas` accepts 2–6 pods and `postgres_instances` accepts 2–8 managed
database nodes. Neither tier permits a single-instance configuration. Orthanc
pods share the PostgreSQL index and S3-compatible Object Storage payloads; the
Kubernetes Service updates its backends automatically and required topology
spread places ready Orthanc pods on at least two workers. The PostgreSQL primary
endpoint remains the Orthanc read/write target while OCI promotes a replica if
the primary node fails. The optional reader endpoint is deliberately disabled
because Orthanc index operations are not read-only.

`keycloak_replicas` defaults to two and must remain at least two; its distributed
cache discovers peers through the shared database. Increase `oke_node_count`
when pod capacity requires it.

Before scaling:

1. Confirm OKE worker shape capacity, node limits, and pod-subnet addresses.
2. Confirm the node and NLB subnets have sufficient addresses.
3. Increase PostgreSQL OCPUs/memory or node count if index pressure is the
   bottleneck. Each added node incurs its own Compute cost.
4. Review Network Load Balancer throughput and FastConnect capacity.

Multiple Orthanc replicas use `PostgreSQL.Lock = false`, as required for shared
index access, and `TransactionMode = ReadCommitted` for concurrent writers.
Keep every replica on the same pinned image and configuration. Do not perform a
rolling Orthanc upgrade when the PostgreSQL plugin requires a schema migration;
stop all replicas, migrate once, and then start the identical new version.

## Credential rotation

For generated credentials, use Terraform replacement and then run
`make deploy-oke` so Kubernetes secrets and dependent pods are updated:

```bash
terraform -chdir=terraform apply \
  -replace=random_password.postgres \
  -replace=random_password.keycloak_database \
  -replace=random_password.orthanc \
  -replace='oci_identity_customer_secret_key.orthanc[0]'
```

Review the plan carefully. Replacing the PostgreSQL password may require a
service-supported password update and coordinated Orthanc replacement. Test
rotation in a non-production stack first.

Do not replace `random_password.keycloak_admin`: Keycloak consumes that value
only when it bootstraps an empty master realm. To rotate the master
administrator, change it through the Keycloak Admin API/console first, then set
the sensitive `keycloak_admin_password` input to that exact value before the
next deployment. The day-two reconciler uses it to authenticate.

Realm import remains bootstrap-only, but stack configuration no longer depends
on repeated import. `make deploy-oke` idempotently reconciles realm settings,
roles, the Orthanc client, managed local users and passwords, and the optional
OCI identity provider. Replacing `random_password.orthanc`, changing tenants,
or disabling SSO therefore converges on an existing database.

For an existing storage identity, create a second Customer Secret Key, update
the sensitive input variables, apply, verify all replicas and Object Storage
reads/writes, then delete the old key.

## Backup and recovery

- PostgreSQL daily backup retention defaults to 14 days.
- Object versioning is enabled by default.
- Object Storage versioning is not an application-consistent database backup.
- A complete recovery procedure must restore PostgreSQL to a matching point in
  time and preserve the corresponding Object Storage versions.

Exercise restore into an isolated compartment. Validate study/series/instance
counts and retrieve representative objects before declaring the restore usable.

The repository includes a managed-service restore drill that performs the
database half of that procedure without overwriting the source system:

```bash
make restore-drill PRIVATE_KEY=/absolute/path/to/id_rsa
```

It creates an on-demand backup, creates a one-node temporary OCI PostgreSQL
system from the backup in the private database subnet, queries the restored
Orthanc and Keycloak schemas from the bastion, and deletes both drill
resources. The EXIT cleanup is intentional: a failed verification must not
leave unmanaged billable resources that later block stack decommissioning.
Retain the command output as recovery evidence. A production recovery exercise
must additionally restore or select matching Object Storage versions and run
representative WADO-RS reads.

For regional disaster recovery, add Object Storage replication and PostgreSQL
cross-region backup copy policies according to the organization's RPO/RTO and
data-residency rules. They are not enabled generically because destination
region and legal residency requirements are deployment-specific.

## Upgrades

1. Read Orthanc core, PostgreSQL, DICOMweb, S3, Stone, and OHIF plugin release notes.
2. Pin a new `orthanc_image` tag in a non-production workspace.
3. Run API checks and upload/retrieve/delete lifecycle tests.
4. Review database schema migration and rollback compatibility.
5. Apply in production and monitor backend health and 5xx rates.

Kubernetes performs a rolling deployment and the NLB removes unhealthy
backends from rotation. Upgrade OKE control plane and nodes one supported
version at a time. Do not use a floating `latest` image tag.

## Large-file ingest

API Gateway rejects request bodies over 20 MB. Bulk ingest needs a private VCN
path over FastConnect or a purpose-built chunking/ingest service. When
FastConnect is enabled, validate the control plane first:

```bash
scripts/verify-fastconnect.sh --control-plane-only
```

From a FastConnect-connected on-premises host, validate routing, TLS, and APIs:

```bash
scripts/verify-fastconnect.sh
scripts/verify-fastconnect.sh --dicom /absolute/path/to/large-test.dcm
```

The private path does not traverse API Gateway and therefore does not have its
20 MB request limit. Validate:

- private DNS and routing
- DRG route distributions
- on-premises and OCI CIDR non-overlap
- NSG rules restricted to the on-premises CIDRs
- transfer retry/idempotency and storage validation

Review [fastconnect.md](fastconnect.md) before activation. A virtual circuit
remaining `PENDING_PROVIDER` or `DOWN` is expected until the carrier activates
the order and on-premises BGP is established.

Traditional DICOM C-STORE port 4242 is disabled in this stack. If required,
expose it only through a private Network Load Balancer, enable DICOM TLS, and
restrict calling AEs and network sources.

## Tenant classification

Tenant isolation is enforced with one configured Orthanc study label per
tenant. New STOW-RS/REST uploads are intentionally unlabeled and invisible to
tenant roles. A trusted classifier reviews the ingest source and assigns the
label using a DICOM Study Instance UID or Orthanc study ID:

```bash
make classify-study TENANT=hospital-a STUDY_UID=2.25.1234
make classify-study TENANT=hospital-a STUDY_ID=orthanc-internal-id
```

Do not derive this decision solely from uploader-controlled DICOM tags. The
script rejects labels outside the Terraform tenant catalog, removes competing
configured tenant labels, and confirms that exactly one remains. The global
platform roles cross tenant boundaries and must be restricted to central
operators. A person with two tenant role groups receives the union of both
authorized labels by design.

Run `make verify-compliance` after tenant or authorization changes. It uploads
two synthetic studies, confirms quarantine, classifies one into each of two
tenants, proves positive QIDO/WADO access and cross-tenant denial, verifies
audit/storage/database evidence, then removes the studies. Disable
`enable_tenant_test_users` and apply after acceptance.

## Failure exercise

With at least two Orthanc replicas, run:

```bash
make failure-test PRIVATE_KEY=/absolute/path/to/id_rsa
```

The script deletes one Orthanc pod, probes public QIDO-RS throughout the
replacement window, waits for the deployment to recover, and confirms the old
pod was replaced. It does not delete a study or any OCI resource.

## Decommissioning

1. Stop new ingest and record the approved retention disposition.
2. Export and verify required studies and audit evidence.
3. Run `make destroy`. No bastion SSH key or separate Kubernetes namespace
   cleanup is required. The workflow revokes SSO grants while their application
   is active, deactivates that application, destroys OKE, deletes its exact
   Kubernetes-managed NLB, removes the stack-specific OCI custom claim, and
   then runs the final Terraform destroy. It also recovers this ordering when
   retrying an already-partial destroy. If the
   bucket is non-empty, destroy fails by design and leaves the DICOM data intact.
4. If retention requires preserving the data, do not bypass that failure.
5. If an authorized data custodian has approved permanent deletion, run
   `make destroy-purge`. The script displays the managed bucket and requires
   typing `purge <bucket-name>`.
6. The purge path uses OCI's bucket `--empty` operation to permanently delete
   current and versioned objects, pre-authenticated requests, replication
   policies, and uncommitted multipart uploads before Terraform destroys the
   remaining resources. An active retention rule can still block deletion.
7. Use `make destroy-purge-auto` only in controlled automation where that
   irreversible deletion has already been approved.
8. The destroy workflow automatically retries recognized transient OCI endpoint
   DNS failures during init, planning, targeted cleanup, and final destruction.
   It does not retry Terraform configuration, IAM, quota, or service errors.
   Defaults can be adjusted with `TERRAFORM_NETWORK_RETRY_ATTEMPTS` and
   `TERRAFORM_NETWORK_RETRY_DELAY_SECONDS` when a controlled runner has a slow
   corporate or VPN resolver.
9. Retain the final Terraform and OCI CLI output as cleanup evidence.
