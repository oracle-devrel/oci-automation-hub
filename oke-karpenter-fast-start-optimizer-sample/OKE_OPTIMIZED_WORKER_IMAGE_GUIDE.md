<!-- Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. -->
<!-- The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ -->

# Optimized OKE Oracle Linux Worker Image Guide

This guide documents the exact implementation used for the `OKEOptimization` cluster to create faster-starting Oracle Linux 8.10 OKE workers launched by Oracle's Karpenter Provider for OCI (KPO).

The pattern is:

1. Start from an Oracle-published OKE worker image, not a generic Oracle Linux image.
2. Build a custom image that already contains the packages and container layers that normally delay first boot.
3. Use KPO/Karpenter to launch nodes from that custom image only when pending workload pods require capacity.
4. Use optimized KPO `user_data` to bootstrap the node with one IMDS read and a direct `oke-install.sh` invocation.
5. Measure the node lifecycle with explicit bootstrap markers.

## Final Environment

The implementation in this repository uses:

| Component | Value |
| --- | --- |
| Region | `us-ashburn-1` |
| OKE version | `v1.35.2` |
| KPO chart version | `v1.1.0` |
| Base worker image | `Oracle-Linux-8.10-2026.02.28-0-OKE-1.35.2-1402` |
| Base image OCID | `<base-oke-worker-image-ocid>` |
| Custom image name | `oke-optimization-ol8-oke-1-35-2-fast-start` |
| Custom image OCID | Generated during image build |
| Karpenter NodePool / OCINodeClass | `optimized-ol8` |
| Karpenter worker shape | `VM.Standard.E5.Flex` |
| Karpenter worker size | `4 OCPU`, `16 GB` memory |
| NodePool limits | `cpu: "96"`, `memory: 384Gi` |
| CNI | `OCI_VCN_IP_NATIVE` |
| Secondary VNIC pod IP count | `16` |

Important: rebuild the custom image whenever the OKE worker image, Kubernetes minor/patch version, region, or required pre-pulled image set changes.

## Implementation Files

The current implementation is split across these files:

| File | Purpose |
| --- | --- |
| `image_builder.tf` | Launches the temporary image-builder VM, waits for the build marker, stops the VM, and creates the custom image. |
| `templates/image-builder-cloud-init.sh.tftpl` | Performs image-time package install, CRI-O image pre-pulls, verification, and cleanup. |
| `karpenter.tf` | Installs KPO, creates the `OCINodeClass`, and creates the `NodePool`. |
| `templates/karpenter-optimized-user-data.sh.tftpl` | Runtime bootstrap wrapper used by KPO-launched nodes. |
| `locals.tf` | Renders KPO user data, shape configs, network config, and custom image tags. |
| `variables.tf` | Defines worker shape, limits, pre-pulled images, image version, and region defaults. |
| `iam.tf` | Creates the KPO workload identity policies and node dynamic group policy for `CLUSTER_JOIN`. |

## Step 1: Use Karpenter/KPO for Scale From Zero

Use Karpenter Provider for OCI rather than a fixed-size managed node pool for the scaling test workers.

Why:

- Karpenter reacts to unschedulable pods and creates just enough nodes.
- The optimized workers can scale from zero; no idle optimized workers are required before the test.
- It avoids mixing scaling-test workloads with the small managed OKE node pool that hosts the KPO controller.

Implementation details:

- The cluster still has one regular OKE managed bootstrap node pool for the KPO controller.
- Optimized application pods are forced onto Karpenter nodes by using:
  - node selector: `oke-optimization.oracle.com/profile=fast-start`
  - toleration: `oke-optimization.oracle.com/scaling-test=true:NoSchedule`
- The Karpenter NodePool applies the matching label and taint:
  - label: `oke-optimization.oracle.com/profile=fast-start`
  - taint: `oke-optimization.oracle.com/scaling-test=true:NoSchedule`

This makes the test a true scale-from-zero test. If 100 pods are created, they cannot land on the regular OKE bootstrap node.

## Step 2: Start From an OKE-Ready Oracle Linux Image

Use the Oracle-published OKE worker image for the exact Kubernetes version.

For this implementation:

```text
Oracle-Linux-8.10-2026.02.28-0-OKE-1.35.2-1402
```

Why:

- OKE worker images already contain OKE-specific bootstrap assets such as `/etc/oke/oke-install.sh`.
- KPO expects an OKE-compatible image when using `imageType = "OKEImage"`.
- Starting from a generic Oracle Linux image would require recreating OKE bootstrap behavior and would be fragile.

The custom image must be rebuilt for each OKE worker image version. Do not reuse a custom image built for an older OKE Kubernetes release unless it has been explicitly validated against the target cluster version.

## Step 3: Build a Custom Image With a Temporary Builder VM

Terraform launches a temporary OCI compute instance from the base OKE image.

Builder settings used here:

| Setting | Value |
| --- | --- |
| Shape | `VM.Standard.E5.Flex` |
| OCPUs | `4` |
| Memory | `16 GB` |
| Boot volume | same worker boot volume size as the Karpenter workers |
| Network | dedicated public image-builder subnet |
| SSH | configured project public key |

Why:

- The builder VM runs the same OS and OKE worker image that Karpenter nodes will use.
- Any files, packages, and CRI-O image layers written during the build are captured into the custom image.
- Terraform can verify the build over SSH before creating the custom image.

The builder workflow is:

1. Launch builder from the base OKE worker image.
2. Run `templates/image-builder-cloud-init.sh.tftpl`.
3. Wait for `/var/lib/oke-optimization/image-build-complete`.
4. Soft-stop the builder VM with OCI CLI.
5. Create `oci_core_image.optimized_oke_worker` from the stopped instance.
6. Tag the image with the base image and optimization metadata.

## Step 4: Bake Package Downloads Into the Image

The builder installs:

```bash
dnf -y install oraclelinux-developer-release-el8
dnf -y install jq curl python36-oci-cli
```

Why:

- Internal testing identified node-start downloads as one of the largest delays in cold boot.
- Installing these packages during every Karpenter node boot depends on repository availability, mirror latency, and node network startup timing.
- `jq` is required by the optimized runtime bootstrap script to parse the single IMDS JSON response.
- `curl` is required by the optimized bootstrap path.
- `python36-oci-cli` was included because the original image-bake path included it and because some OKE/customer bootstrap variants use OCI CLI during node setup. The final optimized runtime script does not use OCI CLI for reserved public IP assignment.

Issue solved:

- Removes package manager and external repository latency from every Karpenter scale-up node.
- Avoids repeated package downloads during large scale-out events.

What helped:

- Baking downloads into the image is one of the most important optimizations. The initial analysis estimated this class of delay at roughly 45-90 seconds per node in the original cold-start path.

## Step 5: Pre-Pull Core OKE Images at Image Build Time

The builder starts CRI-O only during the image build:

```bash
systemctl start crio
```

Then it pre-pulls these Ashburn-region OKE images into CRI-O storage:

```text
iad.ocir.io/axoxdievda5j/oke-public-pause@sha256:6e287874898efea60adff9dc1faaee355740b192763f963fe66cf755d995cf32
iad.ocir.io/id9y6mi8tcky/oke-public-vcn-native-ip-cni-plugin@sha256:916f9953b84f2788b410c45ba766901e99d9c345d37e2fc35a16c312f27e34f0
iad.ocir.io/id9y6mi8tcky/oke-public-kube-proxy@sha256:175559244baa3cbee68adfc1357c18871406c7a2d49dd487d2f04e111e7931a0
```

Why:

- The original cloud-init pre-pulled `pause`, the VCN-native CNI plugin, and `kube-proxy`.
- Pulling those images during runtime adds registry/network latency to every new node.
- During a large scale-out event, many nodes pulling the same images at once can amplify registry and network delay.
- Digest-pinned images are deterministic and avoid unexpected `latest` tag changes.

Issue solved:

- Removes core OKE image pull latency from the critical path.
- Reduces registry fan-out during scale tests.

What helped:

- This helped, but the implementation that helped was image-time pre-pull, not runtime pre-pull. Later pod events showed image pulls were either already present or completed in a few hundred milliseconds, so image pull was no longer the scaling bottleneck.

## Step 6: Verify Pre-Pulled Images Before Capturing the Image

The image build verifies each configured image exists in CRI-O storage:

```bash
crictl images --digests | grep -F "$image_repo" >/dev/null
```

Why:

- A custom image that silently misses one of the expected layers is hard to diagnose later.
- Verification fails the image build visibly instead of producing a partially optimized image.

Issue solved:

- Prevents false-positive image builds.
- Ensures the later Karpenter scale test is testing the intended optimization.

## Step 7: Clean Only Transient Builder State

The builder cleans transient data before image capture:

```bash
dnf clean all
rm -rf /var/cache/dnf/* /var/tmp/* /tmp/*
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance
rm -f /root/.bash_history /home/opc/.bash_history
find /var/log -type f ! -name "oke-optimized-image-build.log" -exec truncate -s 0 {} \; || true
truncate -s 0 /etc/machine-id || true
```

Why:

- Cloud-init instance state must not be baked into a reusable image.
- Machine identity must be regenerated per instance.
- DNF cache and temporary files should not inflate the image.
- The OKE bootstrap assets and CRI-O image storage must be preserved.

Issue solved:

- Avoids cloned machine identity and stale cloud-init state.
- Keeps the image reusable while preserving the pre-pulled image layers.

Important:

- Do not delete `/etc/oke`.
- Do not delete CRI-O container storage after pre-pulling images.

## Step 8: Tag the Custom Image

The custom image is tagged with:

```hcl
k8s_version          = "v1.35.2"
base_image_ocid      = "<base-oke-worker-image-ocid>"
base_image_name      = "Oracle-Linux-8.10-2026.02.28-0-OKE-1.35.2-1402"
optimization_profile = "fast-start"
```

Why:

- Teams need to know exactly which OKE worker image a custom image was built from.
- Karpenter worker images are tightly coupled to OKE/Kubernetes versions.
- Tags make image provenance clear during later audits and rebuilds.

Issue solved:

- Prevents accidental use of stale or mismatched worker images.

## Golden Image Drift and Staleness Risks

If this image build process is moved to Packer, the same optimization pattern still applies. Packer replaces the Terraform temporary-builder workflow, but the output is still a golden image. That means all baked packages and pre-pulled container layers are frozen at image-build time.

Items frozen into the image include:

- OS packages installed with `dnf`
- `oraclelinux-developer-release-el8`
- `jq`
- `curl`
- `python36-oci-cli`
- CRI-O cached image layers
- any application images teams choose to pre-pull

Why this matters:

- The speed improvement comes from not downloading those items during every node boot.
- The risk is that the image can drift behind Oracle's latest OKE worker image, OS package fixes, CRI-O fixes, OCI CLI fixes, or newer Kubernetes infrastructure image digests.
- A stale image may continue to boot successfully while silently missing security fixes or compatibility updates.

Pre-pulled image behavior:

- Pre-pulling an image into CRI-O does not permanently force Kubernetes to use that layer if the live DaemonSet asks for a different image reference.
- If the requested image digest is different, CRI-O must pull the different digest.
- If the requested image uses a mutable tag such as `latest`, cached behavior can become ambiguous and may use stale content depending on pull policy and runtime behavior.
- For that reason, this implementation uses region-correct digest-pinned images instead of mutable `latest` tags.

Required operating model:

1. Treat the optimized worker image as versioned per OKE/Kubernetes version.
2. Rebuild from Oracle's newest certified OKE worker image for the target Kubernetes version.
3. Rebuild when any pre-pulled image digest changes.
4. Rebuild on a regular security cadence, such as monthly, even if the OKE version does not change.
5. Promote a new image only after a node-join smoke test and Karpenter scale test.
6. Tag each image with build timestamp, base image OCID, base image name, Kubernetes version, optimization profile, and the pre-pulled image digest set.
7. Retire old optimized images after the replacement has passed validation.

Important package guidance:

- Prefer rebuilding from Oracle's latest OKE worker image over heavily mutating an older worker image.
- Do not run a broad, untested `dnf update -y` on top of an OKE worker image without validation.
- OKE worker images are curated artifacts; replacing core packages outside Oracle's image cadence can introduce compatibility risk.
- If a security team requires package updates between Oracle OKE image releases, validate the updated image with a full node join, CNI, kube-proxy, DaemonSet, and workload scheduling test before promotion.

## Step 9: Configure KPO to Use the Custom Image

The `OCINodeClass` uses the custom image in the boot volume image config:

```yaml
volumeConfig:
  bootVolumeConfig:
    imageConfig:
      imageType: OKEImage
      imageId: <custom-image-ocid>
```

Why:

- This tells KPO to launch OKE-compatible workers from the optimized image.
- Karpenter still owns instance creation, but the boot disk comes from the prebuilt fast-start image.

Issue solved:

- Ensures every Karpenter-provisioned worker starts with the baked packages and CRI-O image layers.

## Step 10: Use Full KPO `metadata.user_data` for Runtime Bootstrap

The final bootstrap script is rendered into:

```yaml
OCINodeClass.spec.metadata.user_data
```

It is not implemented as a small pre-bootstrap hook. The full user-data wrapper owns the optimized bootstrap path and then invokes Oracle's OKE installer.

Why:

- The node still needs cluster-specific data at runtime: API server endpoint, cluster CA, DNS, and node identity.
- Those values cannot be fully baked into the image.
- KPO-provided user data is the right place to combine runtime metadata with the prebuilt image.

Issue solved:

- Keeps the image reusable across node instances while avoiding repeated metadata/polling behavior.

## Step 11: Fetch IMDS Once

The runtime bootstrap performs one IMDS call:

```bash
INSTANCE_JSON=$(curl -sfL -m 5 --retry 3 \
  -H "Authorization: Bearer Oracle" \
  "http://169.254.169.254/opc/v2/instance")
```

Then it extracts values locally:

```bash
APISERVER=$(echo "$INSTANCE_JSON" | jq -er '.metadata.apiserver_host')
CA_CERT=$(echo "$INSTANCE_JSON" | jq -er '.metadata.cluster_ca_cert')
DNS=$(echo "$INSTANCE_JSON" | jq -r '.metadata.cluster_dns // .metadata.kubedns_svc_ip // "<cluster-dns-ip>"')
```

Why:

- Internal analysis found that multiple sequential metadata calls and installer polling added measurable startup delay.
- A single metadata document fetch removes repeated IMDS round trips.
- Local `jq` extraction is fast and deterministic.

Issue solved:

- Avoids repeated IMDS curl calls during the critical boot path.
- Ensures the bootstrap script fails clearly if required metadata is missing.

What helped:

- This was one of the direct recommendations from the optimization notes and it remains in the final implementation. It is part of the faster and more predictable bootstrap path.

## Step 12: Call `/etc/oke/oke-install.sh` With Explicit Values

The implementation does not modify Oracle's `/etc/oke/oke-install.sh` file.

The enhancement is in how the script is invoked:

```bash
bash /etc/oke/oke-install.sh \
  --apiserver-endpoint "$APISERVER" \
  --kubelet-ca-cert "$CA_CERT" \
  --cluster-dns "$DNS" \
  --kubelet-extra-args "$KUBELET_ARGS"
```

Why:

- Internal analysis identified that passing explicit values avoids internal metadata lookup and polling loops in the installer path.
- Keeping Oracle's script unmodified reduces maintenance risk when OKE worker images change.
- The custom wrapper is easier to diff and validate than a patched Oracle bootstrap script.

Issue solved:

- Removes avoidable discovery/polling time from the bootstrap path.
- Preserves vendor-provided OKE bootstrap behavior.

What helped:

- This materially helped. It is one of the key runtime optimizations that stayed in the final implementation.

## Step 13: Set Kubelet Reservations Explicitly

The runtime bootstrap passes:

```bash
KUBELET_ARGS="\
--kube-reserved=cpu=70m,memory=1Gi \
--system-reserved=cpu=100m,memory=256Mi \
--eviction-hard=memory.available<500Mi"
```

Why:

- The optimization notes called out that default reservations on smaller nodes were too low.
- Undersized reservations can lead to node pressure, instability, and delayed readiness under load.
- The current demo workers are modestly sized at 4 OCPU and 16 GB memory, so explicit reservations are appropriate.

Issue solved:

- Improves node stability during bootstrap and scale tests.
- Reduces risk that DaemonSets, kubelet, or system processes compete too aggressively with workload pods.

What helped:

- This is primarily a stability improvement, not the largest raw boot-speed improvement. It should be treated as a best-practice baseline for smaller worker nodes.

## Step 14: Do Not Start CRI-O or Pull Images at Runtime

The attached cloud-init started background pulls during bootstrap. That was tested, but the final implementation removed runtime CRI-O start and runtime pull loops.

Final runtime behavior:

- Do not run `systemctl start crio` before `oke-install.sh`.
- Do not run background `crictl pull` loops before or during `oke-install.sh`.
- Go from IMDS extraction directly to `/etc/oke/oke-install.sh`.

Why:

- Starting CRI-O manually during runtime can race with OKE bootstrap's own service ordering.
- Node-side analysis showed CRI-O-related stalls and worse launch-to-register timing when runtime CRI-O start/pulls were present.
- The image-time pre-pull already captures the useful part of the image pull optimization.

Issue solved:

- Avoids CRI-O bootstrap races.
- Keeps image pull latency out of the node boot path without destabilizing OKE startup.

What helped:

- The concept of pre-pulling helped.
- Runtime background pulls did not help in this environment once the image was pre-baked; they hurt consistency.
- The final winning design is "pre-pull during image build, then leave CRI-O startup to OKE bootstrap at runtime."

## Step 15: Add Bootstrap Timing Markers

The runtime bootstrap writes a timing log:

```text
/var/log/oke-optimized-bootstrap-timing.log
```

It also writes marker files under:

```text
/var/lib/oke-optimization/
```

Events recorded:

```text
imds-fetch-start
imds-fetch-end
oke-installer-start
oke-installer-end
kubelet-active
node-ready
```

Each log line includes:

- ISO timestamp
- epoch timestamp
- node uptime seconds
- event name

Why:

- Karpenter and Kubernetes events show the outside view of provisioning.
- Node-side markers show where time is spent inside the guest OS.
- Future teams can separate OCI provisioning time from node bootstrap time.

Issue solved:

- Makes boot regressions measurable.
- Prevents guessing whether the bottleneck is OCI provisioning, OKE install, kubelet activation, image pulls, or scheduling.

## Step 16: Configure KPO IAM Correctly

KPO needs workload identity permissions to create and manage OCI resources.

Implemented KPO workload policies allow the KPO service account to:

- manage `instance-family`
- manage `volumes`
- manage `volume-attachments`
- manage `virtual-network-family`
- read `instance-images`
- inspect compartments

Karpenter-launched nodes also need `CLUSTER_JOIN`.

Implemented node dynamic group:

```text
ALL {instance.compartment.id = '<OKEOptimization compartment OCID>'}
```

Implemented node policy:

```text
Allow dynamic-group <karpenter-node-dynamic-group> to {CLUSTER_JOIN}
in compartment OKEOptimization
where target.cluster.id = '<cluster OCID>'
```

Why:

- KPO cannot launch nodes without OCI compute/network permissions.
- Self-managed Karpenter nodes cannot join OKE without `CLUSTER_JOIN`.

Issue solved:

- Prevents nodes from launching but failing to register with the cluster.
- Keeps the permissions scoped to the project compartment and cluster.

## Step 17: Tune NodePool Behavior for the Demo

The final NodePool settings are:

```yaml
disruption:
  budgets:
  - nodes: 100%
  consolidateAfter: 30s
  consolidationPolicy: WhenEmptyOrUnderutilized
template:
  spec:
    terminationGracePeriod: 2m
limits:
  cpu: "96"
  memory: 384Gi
```

Why:

- `consolidateAfter: 30s` makes the demo scale down quickly after workloads are deleted.
- `WhenEmptyOrUnderutilized` allows downsizing when nodes are empty or underutilized.
- `nodes: 100%` allows aggressive disruption for a demo cluster.
- `terminationGracePeriod: 2m` prevents long termination delays during demos.
- The limits were raised from `64/256Gi` to `96/384Gi` after a 100-pod test hit the cap.

Issue solved:

- Avoids a repeat of the 100-pod test where 8 nodes ran 96 pods and the final 4 pods remained pending because the NodePool CPU limit was exhausted.

## Step 18: Validate the Optimized Image and Runtime Path

After applying Terraform, validate:

```bash
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Verify the custom image:

```bash
oci compute image get --image-id <custom-image-ocid>
```

Confirm:

- lifecycle state is `AVAILABLE`
- image compartment is `OKEOptimization`
- tags include `k8s_version`, `base_image_ocid`, `base_image_name`, and `optimization_profile = fast-start`

Verify KPO sees the image:

```bash
kubectl --context OKEOptimization get ocinodeclass optimized-ol8 -o yaml
```

Confirm:

- `Ready=True`
- the resolved image ID matches the custom image OCID

Verify the NodePool:

```bash
kubectl --context OKEOptimization get nodepool optimized-ol8 -o yaml
```

Confirm:

- limits are `cpu: "96"` and `memory: 384Gi`
- consolidation is `WhenEmptyOrUnderutilized`
- `consolidateAfter` is `30s`
- taint and label are present

## Step 19: Run a True Scale Test

The test workload must include the selector and toleration:

```yaml
nodeSelector:
  oke-optimization.oracle.com/profile: fast-start
tolerations:
- key: oke-optimization.oracle.com/scaling-test
  operator: Equal
  value: "true"
  effect: NoSchedule
```

Why:

- Without the selector, pods may land on the regular OKE bootstrap node.
- Without the toleration, pods cannot land on the tainted Karpenter nodes.

Example workload sizing used in testing:

```yaml
replicas: 100
resources:
  requests:
    cpu: 500m
    memory: 512Mi
```

For this demo, limits are optional. Scheduling is driven by requests, not limits.

## Step 20: Measure the Scale-Up Path

Use Karpenter and Kubernetes events:

```bash
kubectl --context OKEOptimization get nodeclaims
kubectl --context OKEOptimization get nodes -l karpenter.sh/nodepool=optimized-ol8
kubectl --context OKEOptimization get pods -o wide
kubectl --context OKEOptimization logs -n karpenter deploy/karpenter
```

Use node-side markers:

```bash
sudo cat /var/log/oke-optimized-bootstrap-timing.log
sudo ls -l /var/lib/oke-optimization/
```

The important lifecycle segments are:

| Segment | What it means |
| --- | --- |
| Pod created to Karpenter NodeClaim created | Scheduler/Karpenter reaction time |
| NodeClaim created to launched | KPO and OCI instance launch path |
| Launched to registered | Instance boot plus OKE bootstrap |
| Registered to initialized/Ready | Kubelet, node conditions, and daemon readiness |
| Scheduled to container started | Pod image availability and runtime startup |

In the latest validated run after removing runtime CRI-O start/pulls:

| Segment | Observed result |
| --- | --- |
| NodeClaim create to launched | average about 35s, max about 42s |
| Launched to registered | average about 52s, max about 64s |
| Registered to initialized | average about 11s, max about 16s |
| NodeClaim create to ready | average about 98s, max about 107s |
| Scheduled to container started | average about 14s |

Image pulls were no longer the bottleneck; pod events showed images were already present or pulled in a few hundred milliseconds.

## Optimization Recommendations: Final Status

| Recommendation from optimization notes | Final status | Helped? | Notes |
| --- | --- | --- | --- |
| Use Karpenter with custom OKE images | Implemented | Yes | Enables scale from zero using optimized workers. |
| Bake downloads into a custom/golden image | Implemented | Yes | Removed per-node DNF/repository dependency from boot. |
| Install `oraclelinux-developer-release-el8`, `jq`, `curl`, `python36-oci-cli` | Implemented | Yes | `jq` and `curl` are required by final bootstrap; OCI CLI is baked for compatibility with the original dependency set. |
| Fetch metadata with one IMDS request | Implemented | Yes | Runtime bootstrap fetches `/opc/v2/instance` once and parses locally. |
| Pass explicit API server, CA, and DNS to `oke-install.sh` | Implemented | Yes | Avoids extra discovery/polling while preserving Oracle's installer. |
| Pre-pull `pause`, CNI, and `kube-proxy` | Implemented differently | Yes | Done at image build time with Ashburn digest-pinned images, not as runtime pulls. |
| Start background `crictl pull` during bootstrap | Removed | No, not in final form | Runtime pulls caused consistency issues when combined with OKE bootstrap. Image-time pulls kept the benefit. |
| Add kubelet reservations | Implemented | Yes, mostly stability | Helps small-node reliability and pressure behavior. |
| Reserved public IP logic with OCI CLI | Not implemented | No | The notes also recommended removing it as expensive and edge-case. |
| Warm capacity / warm pools | Not implemented | Potential future work | Would reduce perceived provisioning delay but was outside this Terraform design. |
| Pre-pull application images | Not implemented for demo | Depends on app | Teams should add large application images to `prepull_images` if their workloads are image-pull bound. |

## What Changed in the OKE Installer Path

No changes were made to `/etc/oke/oke-install.sh` itself.

The enhancement is a wrapper that:

1. Fetches metadata once.
2. Extracts API server, CA, and DNS locally.
3. Supplies those values directly to `/etc/oke/oke-install.sh`.
4. Supplies kubelet reservation/eviction args explicitly.
5. Records timing markers around IMDS, installer, kubelet active, and node ready.

This keeps the Oracle-provided installer intact while removing avoidable discovery work around it.

## What Actually Improved Boot Speed

The changes that truly improved or protected boot speed were:

1. Baking dependency downloads into the image.
2. Baking core OKE image layers into CRI-O storage.
3. Fetching IMDS once instead of making multiple metadata calls.
4. Passing explicit bootstrap values to `oke-install.sh`.
5. Removing runtime CRI-O start and background pulls after testing showed they hurt consistency.

The changes that mainly improved operability and demo behavior were:

1. Kubelet reservations.
2. Bootstrap timing markers.
3. NodePool selector/taint isolation.
4. Fast consolidation and 2-minute termination grace.
5. Increased NodePool limits.

## Prescriptive Checklist for a New Team

Use this checklist for each new OKE version or region:

1. Select the Oracle-published OKE worker image for the exact Kubernetes version and region.
2. Launch a temporary builder VM from that image.
3. Install `oraclelinux-developer-release-el8`, `jq`, `curl`, and `python36-oci-cli`.
4. Start CRI-O on the builder only.
5. Pre-pull required OKE infrastructure images by digest into CRI-O storage.
6. Verify the images exist with `crictl images --digests`.
7. Clean DNF cache, cloud-init instance state, logs, temp files, shell history, and machine ID.
8. Do not remove `/etc/oke` or CRI-O image storage.
9. Stop the builder VM.
10. Create a custom OCI image from the stopped builder.
11. Tag the custom image with Kubernetes version, base image OCID, base image name, and optimization profile.
12. Configure KPO `OCINodeClass` to use the custom image as `imageType = "OKEImage"`.
13. Put optimized runtime bootstrap in `OCINodeClass.spec.metadata.user_data`.
14. In runtime bootstrap, fetch IMDS once from `/opc/v2/instance`.
15. Parse API server, cluster CA, and DNS locally with `jq`.
16. Invoke `/etc/oke/oke-install.sh` with explicit endpoint, CA, DNS, and kubelet args.
17. Do not start CRI-O manually at runtime.
18. Do not run runtime background `crictl pull` loops if the image already contains the layers.
19. Add timing markers for IMDS, installer, kubelet active, and node ready.
20. Configure KPO IAM policies and node `CLUSTER_JOIN` dynamic group.
21. Use Karpenter NodePool labels and taints so test workloads only land on optimized nodes.
22. Set NodePool limits high enough for the expected scale test.
23. Validate with Terraform and a real pending-pod scale test.
24. Review Karpenter logs, NodeClaims, Kubernetes events, and node timing markers after each run.

## Common Failure Modes

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Node launches but never joins OKE | Missing `CLUSTER_JOIN` policy for Karpenter nodes | Add compartment-based dynamic group and cluster-scoped `CLUSTER_JOIN` policy. |
| Pods remain pending even though Karpenter works | NodePool CPU/memory limits too low | Raise NodePool limits based on expected nodes and reported Kubernetes CPU capacity. |
| Pods land on the regular OKE node pool | Missing node selector | Add `oke-optimization.oracle.com/profile=fast-start`. |
| Pods cannot land on Karpenter nodes | Missing toleration | Add toleration for `oke-optimization.oracle.com/scaling-test=true:NoSchedule`. |
| Node boot becomes inconsistent | Runtime CRI-O start or runtime image pulls racing OKE bootstrap | Remove runtime CRI-O start/pulls; pre-pull during image build only. |
| Image build succeeds but runtime still pulls core images | Pre-pull verification missing or wrong image region/tag | Use region-correct, digest-pinned images and verify with `crictl images --digests`. |
| Custom image works on one OKE version but not another | Image version mismatch | Rebuild from the OKE worker image for the target Kubernetes version. |

## Summary

The optimized worker image is not just a custom image. The speed comes from combining:

- an OKE-ready base image,
- image-time package baking,
- image-time CRI-O layer pre-pulls,
- a single IMDS metadata fetch,
- direct `oke-install.sh` arguments,
- explicit kubelet reservations,
- no runtime CRI-O interference,
- KPO/Karpenter scale-from-zero behavior,
- correct OCI IAM for KPO and `CLUSTER_JOIN`,
- and repeatable timing validation.

That combination is what produced the improved scale behavior seen in the demo cluster.
