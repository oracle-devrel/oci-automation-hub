# OCI Flexible Load Balancer Benchmark with Locust

This stack benchmarks OCI Flexible Load Balancer connections per second and bandwidth behavior with SSL termination.

It provisions one generator, configurable HTTP backends, and configurable private flexible load balancers. The generator runs the benchmark on both single LB and all LB from one Resource Manager apply, then uploads the results to an existing Object Storage bucket.

## Existing Bucket Requirement

The stack does not create an Object Storage bucket. Provide `results_bucket_name` for a bucket that already exists.

`results_namespace` is optional. When it is blank, the generator uses instance principals and calls Object Storage `get_namespace()` at runtime. If namespace auto detection fails, set `results_namespace` explicitly in Resource Manager.

## IAM Prerequisite

Create a dynamic group that includes the generator instance. For a dedicated benchmark compartment:

```text
ALL {instance.compartment.id = '<benchmark_compartment_ocid>'}
```

Create a policy to allow the dynamic group to upload objects to the existing bucket:

```text
Allow dynamic-group <dynamic_group_name> to manage objects in compartment id <bucket_compartment_ocid> where target.bucket.name = '<results_bucket_name>'
```

Use the compartment OCID that has the bucket in the policy.

## Data Path

```text
generator -> HTTPS/TCP 443 -> OCI FLB SSL termination -> HTTP/TCP 80 -> NGINX backends
```

No PROXY protocol is used. Backends serve `/healthz` and static `/payload_size` files on port 80.

## Stateless Security Rule Mode

By default, NSG rules are stateful. For CPS focused testing, set `use_stateless_security_rules = true`.

Use this as a measured optimization, not an assumed fix. Run the same topology, shapes, CPS tiers, and throughput tiers with the toggle disabled and enabled, then compare `recommendations.json`, Locust failures, and OCI metrics.

## Results

Local artifacts are written on the generator under:

```text
/opt/flb-benchmark/results/<run_id>/
```

Uploaded artifacts are written to Object Storage under:

```text
<results_prefix>/<run_id>/
```

Important files include:

- `config.json`
- `readiness.json`
- `index.json`
- `recommendations.json`
- `controller.log`
- `<run_id>.tar.gz`
- per test `summary.json`, Locust CSV files, Locust HTML report, and Locust log
- `locust-worker-*.log`
- `failure.json` when a run fails

If upload fails, SSH to the controller and inspect `/opt/flb-benchmark/results`, `/var/log/flb-benchmark-generator.log`, and `journalctl -u flb-benchmark-controller.service`.

## Interpreting Results

One generator can become the bottleneck before the load balancer. Use generator shape, OCPU count, worker count, response latency, failure rate, and generator side logs when interpreting measured capacity.

CPS is marked stable when failure rate is at most 1% and the achieved request rate is at least 90% of the CPS target.

Throughput is marked stable when failure rate is at most 1% and achieved Gbps is at least 85% of target.

Compare `single_lb` and `all_lbs` entries in `recommendations.json` and `index.json` to understand single LB behavior, aggregate all LB behavior, and scale efficiency.

## Deploy to OCI

Launch this stack directly in OCI Resource Manager.

<p align="center">
  <a href="https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/oracle-devrel/oci-automation-hub/releases/download/benchmark-load-balancer-sample/benchmark-load-balancer-sample.zip">
    <img src="https://docs.oracle.com/en-us/iaas/Content/Resources/Images/deploy-to-oracle-cloud.svg" alt="Deploy to Oracle Cloud" />
  </a>
</p>

## Download results from bucket

It might take a while, depending on how many workers you choose, if it's single LB or more.
To download the folder containg the results run:

```
oci os object bulk-download \
    --region <bucket_region> \
    -ns <object_storage_namespace> \
    -bn <bucket_name> \
    --prefix "<results_prefix/run_id/>" \
    --download-dir ./ \
    --overwrite
```
