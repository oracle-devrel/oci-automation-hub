# Iceberg Table Migration to OCI

This repository is a Terraform-based demo for migrating an Apache Iceberg table into OCI Object Storage and validating it with Spark.

Current primary run mode:

```text
local terminal -> terraform apply -> SSH to OCI VM -> run /opt/iceberg scripts
```

## What It Does

Terraform provisions:

- OCI network
- OCI compute VM
- OCI Object Storage bucket
- cloud-init bootstrap on the VM

Cloud-init installs and prepares:

- Docker
- Spark
- Apache Iceberg runtime
- PostgreSQL
- Hive Metastore container
- Iceberg JDBC catalog
- OCI CLI and AWS CLI
- helper scripts under `/opt/iceberg`

The demo scripts then:

1. Generate a real tiny Iceberg table using Silo as fake AWS S3.
2. Export real Iceberg `data/` and `metadata/` files.
3. Copy those files into OCI Object Storage.
4. Register the copied table in Iceberg JDBC catalog.
5. Validate with Spark.
6. Optionally validate with Trino.

## Terraform Options

Optional Trino validation is controlled by the Terraform variable `validation_engines`.

Set it in `terraform.tfvars` before `terraform apply`:

```hcl
validation_engines = ["spark", "trino"]
```

Default is Spark only:

```hcl
validation_engines = ["spark"]
```

The included `terraform.tfvars` may already set `["spark", "trino"]`; change it to `["spark"]` if you want Spark-only validation.

You can also override it for one VM run:

```bash
export VALIDATION_ENGINES="spark,trino"
```

## Configure Terraform Inputs

Populate these values before running Terraform.

In `provider.auto.tfvars`:

- `provider_oci.tenancy_ocid`: tenancy OCID from OCI.
- `provider_oci.user_ocid`: user OCID for the API key owner.
- `provider_oci.fingerprint`: fingerprint of the uploaded OCI API key.
- `provider_oci.private_key_path`: local path to the matching API private key.
- `provider_oci.private_key_password`: private key passphrase, or `""` if the key has none.
- `provider_oci.region`: target OCI region, for example `eu-frankfurt-1`.
- `compartment_ids.sandbox`: compartment OCID where Terraform creates the resources.

In `terraform.tfvars`:

- `linux_images`: Oracle Linux 9 image OCID for the selected `provider_oci.region`.
- `instance_params`: VM availability domain, shape, subnet, image version, OCPUs, and memory.
- `ssh_public_key`, which must point to the public key Terraform should inject into the VM.
- `registry`: OCIR region key, for example `fra.ocir.io` or `iad.ocir.io`.
- `bucket_params`: Object Storage bucket name, compartment name, storage tier, and optional `force_destroy`.
- Network maps: adjust CIDRs, subnet privacy, route rules, and security list rules if the defaults do not fit your tenancy.
- `validation_engines`: use `["spark"]` for Spark only or `["spark", "trino"]` to add Trino validation.

## Quick Run

From this repository:

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

When Terraform asks for confirmation, enter `yes`.

After Terraform finishes, note the public IP address from the `linux_instances` output.

## Post-Deploy Actions

SSH to the compute VM:

```bash
ssh opc@<vm_public_ip>
```

Confirm cloud-init completed and the helper scripts exist:

```bash
cloud-init status --wait --long
docker version
/opt/spark/bin/spark-submit --version
ls -l /opt/iceberg/
```

If the helper scripts are missing, inspect the cloud-init log:

```bash
sudo tail -n 100 /var/log/cloud-init-output.log
```

Generate the simulated AWS Iceberg source table:

```bash
/opt/iceberg/generate-simulated-aws-iceberg-table.sh
```

The default export location is:

```text
/opt/iceberg/generated_aws_source/iceberg-table-demo/lakehouse/sales/orders/
```

Confirm the export contains Iceberg `data/` and `metadata/` files:

```bash
find /opt/iceberg/generated_aws_source/iceberg-table-demo/lakehouse/sales/orders -type f | sort
find /opt/iceberg/generated_aws_source/iceberg-table-demo/lakehouse/sales/orders/metadata -name "*.metadata.json" -type f | sort
```

Copy the generated Iceberg files to OCI Object Storage:

```bash
/opt/iceberg/copy-simulated-source-to-oci.sh
```

Verify the copied objects:

```bash
oci os object list \
  --auth instance_principal \
  --bucket-name iceberg-table-demo \
  --prefix lakehouse/sales/orders/ \
  --fields name \
  --all
```

If you changed the bucket or table prefix, use the same `BUCKET` and `TABLE_PREFIX` values for generation, copy, verification, and registration.

Create an OCI Customer Secret Key for S3-compatible Object Storage access, then set it on the VM. Use the Customer Secret Key access key as `OCI_ACCESS_KEY_ID` and the generated secret value as `OCI_SECRET_ACCESS_KEY`.

```bash
export OCI_ACCESS_KEY_ID="<access-key>"
export OCI_SECRET_ACCESS_KEY="<secret-key>"
```

The VM scripts use the Terraform region by default. Set `OCI_REGION` or `OCI_S3_ENDPOINT` only if you need to override the generated endpoint:

```bash
export OCI_REGION="<oci_region>"
export OCI_S3_ENDPOINT="https://<namespace>.compat.objectstorage.<oci_region>.oci.customer-oci.com"
```

Register the copied table and validate it with Spark:

```bash
/opt/iceberg/register-simulated-oci-table.sh
```

If `validation_engines` includes `trino`, the same registration script also runs Trino validation. You can enable it for one run with:

```bash
export VALIDATION_ENGINES="spark,trino"
/opt/iceberg/register-simulated-oci-table.sh
```

To run a manual Spark SQL check:

```bash
/opt/iceberg/spark-sql-oci.sh
```

```sql
SHOW TABLES IN oci.sales;
DESCRIBE oci.sales.orders;
SELECT * FROM oci.sales.orders;
exit;
```

## Input Modes

The scripts support two source modes:

| Mode | Status | How to use |
| --- | --- | --- |
| `simulated_aws` / Silo | Proven default | Run `generate-simulated-aws-iceberg-table.sh`, then copy/register/validate. |
| `local_export` | Supported as local copy input | Set `SOURCE_DIR` to an existing local Iceberg table export, then run the copy/register flow. |

Inputs must be generated by Iceberg or come from a real exported Iceberg table folder.

### Local Export

The local export folder should contain real Iceberg files:

```text
/path/to/exported/iceberg/table/
  data/
  metadata/
    *.metadata.json
    *.avro
```

Copy it to OCI with:

```bash
SOURCE_DIR=/path/to/exported/iceberg/table \
BUCKET=iceberg-table-demo \
TABLE_PREFIX=lakehouse/sales/orders \
/opt/iceberg/copy-simulated-source-to-oci.sh
```
