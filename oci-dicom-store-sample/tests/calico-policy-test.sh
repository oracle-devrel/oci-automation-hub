#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-calico-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

for profile in 1.33 1.34 1.35 1.36; do
  kubectl kustomize "${project_dir}/kubernetes/calico/${profile}" \
    >"${temporary_dir}/calico-${profile}.yaml"
done
ruby -ryaml - "${temporary_dir}" <<'RUBY'
directory = ARGV.fetch(0)
Dir.glob(File.join(directory, "calico-*.yaml")).sort.each do |path|
objects = YAML.load_stream(File.read(path)).compact
daemonset = objects.find do |item|
  item["kind"] == "DaemonSet" && item.dig("metadata", "name") == "calico-node"
end
raise "calico-node DaemonSet missing" unless daemonset
spec = daemonset.dig("spec", "template", "spec")
raise "CNI init containers remain" if spec.key?("initContainers")
container = spec.fetch("containers").first
raise "envFrom remains" if container.key?("envFrom")
environment = container.fetch("env").to_h { |entry| [entry.fetch("name"), entry["value"]] }
raise "Typha reference remains" if environment.key?("FELIX_TYPHAK8SSERVICENAME")
{
  "FELIX_INTERFACEPREFIX" => "oci",
  "NO_DEFAULT_POOLS" => "true",
  "FELIX_CHAININSERTMODE" => "Append",
  "FELIX_IPTABLESMANGLEALLOWACTION" => "Return",
}.each { |name, value| raise "bad #{name}" unless environment[name] == value }
removed = ["cni-bin-dir", "cni-net-dir", "cni-log-dir"]
raise "CNI mount remains" unless (removed & container.fetch("volumeMounts").map { |item| item.fetch("name") }).empty?
raise "CNI volume remains" unless (removed & spec.fetch("volumes").map { |item| item.fetch("name") }).empty?
end
RUBY

printf 'Oracle-supported Calico profiles render in OCI VCN-native policy-only mode.\n'
