#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-manifest-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

cat >"${temporary_dir}/main.tf" <<'HCL'
variable "template_path" { type = string }
variable "large_upload" { default = true }
locals {
  values = {
    namespace                     = "dicom-test"
    orthanc_replicas              = 2
    keycloak_replicas             = 2
    orthanc_image                 = "example.invalid/orthanc:1"
    orthanc_auth_service_image    = "example.invalid/auth:1"
    keycloak_image                = "example.invalid/keycloak:1"
    nginx_image                   = "example.invalid/nginx:1"
    postgres_client_image         = "example.invalid/postgres:1"
    orthanc_config_b64            = "e30="
    orthanc_explorer_css_b64      = "LmhpZGRlbiB7IGRpc3BsYXk6IG5vbmU7IH0="
    permissions_b64               = "e30="
    keycloak_realm_b64            = "e30="
    nginx_config_b64              = "e30="
    postgres_host                 = "10.42.20.10"
    postgres_username_b64         = "dGVzdA=="
    postgres_password_b64         = "dGVzdA=="
    keycloak_password_b64         = "dGVzdA=="
    keycloak_admin_username_b64   = "dGVzdA=="
    keycloak_admin_password_b64   = "dGVzdA=="
    orthanc_auth_users_b64        = "e30="
    orthanc_auth_secret_b64       = "dGVzdA=="
    public_base_url               = "https://example.invalid"
    nlb_private_ip                = "10.42.10.10"
    nlb_subnet_id                 = "ocid1.subnet.test"
    nlb_nsg_id                    = "ocid1.networksecuritygroup.test"
    compartment_id                = "ocid1.compartment.test"
    keycloak_trusted_proxy_cidr   = "10.42.12.0/22"
    oke_nodes_subnet_cidr         = "10.42.8.0/24"
    postgres_cidr                 = "10.42.20.10/32"
    gateway_ingress_cidrs         = ["10.42.0.0/24", "192.0.2.0/24"]
    orthanc_host_id               = "12345678"
    enable_large_upload_endpoint = var.large_upload
    large_upload_ip = "192.0.2.20"
    large_upload_subnet_id = "ocid1.subnet.public"
    large_upload_nsg_id = "ocid1.networksecuritygroup.upload"
    large_upload_cert_b64 = "dGVzdA=="
    large_upload_key_b64 = "dGVzdA=="
    enable_fastconnect            = true
    private_ingest_cert_b64       = "dGVzdA=="
    private_ingest_key_b64        = "dGVzdA=="
    keycloak_bootstrap_id         = "0123456789ab"
    orthanc_config_hash           = "orthanc"
    auth_service_config_hash      = "auth"
    keycloak_config_hash          = "keycloak"
    nginx_config_hash             = "nginx"
  }
}
output "rendered" {
  value     = templatefile(var.template_path, local.values)
  sensitive = true
}
HCL

terraform -chdir="${temporary_dir}" init -backend=false >/dev/null
terraform -chdir="${temporary_dir}" apply -auto-approve \
  -var="template_path=${project_dir}/terraform/templates/stack.yaml.tftpl" >/dev/null
terraform -chdir="${temporary_dir}" output -raw rendered >"${temporary_dir}/stack.yaml"

ruby -ryaml - "${temporary_dir}/stack.yaml" <<'RUBY'
source = File.read(ARGV.fetch(0))

check_unique_keys = lambda do |node|
  if node.is_a?(Psych::Nodes::Mapping)
    keys = {}
    node.children.each_slice(2) do |key, value|
      name = key.respond_to?(:value) ? key.value : key.to_s
      raise "duplicate YAML key: #{name}" if keys[name]
      keys[name] = true
      check_unique_keys.call(value)
    end
  elsif node.respond_to?(:children) && node.children
    node.children.each { |child| check_unique_keys.call(child) }
  end
end
check_unique_keys.call(Psych.parse_stream(source))

objects = YAML.load_stream(source).compact
workloads = objects.select { |item| ["Deployment", "Job"].include?(item["kind"]) }
raise "unexpected workload count" unless workloads.length == 5
workloads.each do |workload|
  pod_spec = workload.dig("spec", "template", "spec")
  raise "service token enabled" unless pod_spec["automountServiceAccountToken"] == false
  raise "seccomp missing" unless pod_spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"
  (pod_spec.fetch("initContainers", []) + pod_spec.fetch("containers")).each do |container|
    context = container.fetch("securityContext")
    raise "privilege escalation enabled" unless context["allowPrivilegeEscalation"] == false
    raise "capabilities retained" unless context.dig("capabilities", "drop") == ["ALL"]
  end
end

deployments = objects.select { |item| item["kind"] == "Deployment" }.to_h do |item|
  [item.dig("metadata", "name"), item]
end
raise "Keycloak is not HA" unless deployments.dig("keycloak", "spec", "replicas") == 2
raise "Keycloak spread missing" if deployments.dig("keycloak", "spec", "template", "spec", "topologySpreadConstraints").empty?
raise "authorization spread missing" if deployments.dig("orthanc-auth-service", "spec", "template", "spec", "topologySpreadConstraints").empty?
raise "Orthanc is not HA" unless deployments.dig("orthanc", "spec", "replicas") == 2
orthanc_spread = deployments.dig("orthanc", "spec", "template", "spec", "topologySpreadConstraints").first
raise "Orthanc requires fewer than two nodes" unless orthanc_spread["minDomains"] == 2
raise "Orthanc placement is best-effort" unless orthanc_spread["whenUnsatisfiable"] == "DoNotSchedule"
orthanc_container = deployments.dig("orthanc", "spec", "template", "spec", "containers").find do |container|
  container["name"] == "orthanc"
end
orthanc_env = orthanc_container.fetch("env").to_h { |entry| [entry["name"], entry["value"]] }
raise "Stone Web Viewer plugin is not enabled" unless orthanc_env["STONE_WEB_VIEWER_PLUGIN_ENABLED"] == "true"
raise "OHIF plugin is not enabled" unless orthanc_env["OHIF_PLUGIN_ENABLED"] == "true"
orthanc_mounts = orthanc_container.fetch("volumeMounts").to_h { |mount| [mount["name"], mount] }
raise "Orthanc Explorer customization is not mounted" unless orthanc_mounts.dig("explorer-customization", "mountPath") == "/etc/orthanc-explorer"
explorer_config = objects.find { |item| item["kind"] == "ConfigMap" && item.dig("metadata", "name") == "orthanc-explorer" }
raise "Orthanc Explorer custom CSS is missing" unless explorer_config&.dig("binaryData", "custom.css")

secret = objects.find { |item| item["kind"] == "Secret" && item.dig("metadata", "name") == "orthanc-runtime" }
raise "unused auth username remains" if secret.fetch("data").key?("auth-username")
raise "unused auth password remains" if secret.fetch("data").key?("auth-password")

upload = objects.find { |item| item["kind"] == "Service" && item.dig("metadata", "name") == "dicom-large-upload" }
raise "upload service missing" unless upload
raise "upload exposed over plaintext" unless upload.dig("spec", "ports").map { |p| p["port"] } == [443]
raise "wrong TLS backend" unless upload.dig("spec", "ports", 0, "targetPort") == "large-https"
raise "Cluster mode has incompatible preserve-source annotation" if upload.dig("metadata", "annotations").key?("oci-network-load-balancer.oraclecloud.com/is-preserve-source")
raise "reserved upload IP missing" unless upload.dig("metadata", "annotations", "oci.oraclecloud.com/reserved-ips") == "192.0.2.20"
gateway = deployments.dig("dicom-gateway", "spec", "template", "spec")
raise "upload certificate missing" unless gateway["volumes"].any? { |v| v.dig("secret", "secretName") == "large-upload-tls" }
raise "upload TLS port missing" unless gateway["containers"][0]["ports"].any? { |p| p["name"] == "large-https" && p["containerPort"] == 9443 }

policies = objects.select { |item| item["kind"] == "NetworkPolicy" }.map { |item| item.dig("metadata", "name") }.sort
expected = %w[allow-dns default-deny dicom-gateway keycloak keycloak-database-bootstrap orthanc orthanc-authorization].sort
raise "network policy set differs" unless policies == expected
RUBY

printf 'OKE manifest is valid YAML with hardened workloads and enforced policy definitions.\n'

terraform -chdir="${temporary_dir}" apply -auto-approve \
  -var="template_path=${project_dir}/terraform/templates/stack.yaml.tftpl" \
  -var=large_upload=false >/dev/null
terraform -chdir="${temporary_dir}" output -raw rendered >"${temporary_dir}/disabled.yaml"
ruby -ryaml - "${temporary_dir}/disabled.yaml" <<'RUBY'
objects = YAML.load_stream(File.read(ARGV.fetch(0))).compact
raise "disabled upload resources remain" if objects.any? { |o| %w[dicom-large-upload large-upload-tls].include?(o.dig("metadata", "name")) }
gateway = objects.find { |o| o["kind"] == "Deployment" && o.dig("metadata", "name") == "dicom-gateway" }
ports = gateway.dig("spec", "template", "spec", "containers", 0, "ports")
raise "disabled upload port remains" if ports.any? { |p| p["containerPort"] == 9443 }
RUBY
