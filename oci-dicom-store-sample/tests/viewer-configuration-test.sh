#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-viewer-config-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
validation_public_key="${temporary_dir}/validation.pub"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9jaURpY29tVGVzdFB1YmxpY0tleQ test' \
  >"${validation_public_key}"

viewer_expression='jsonencode({'
viewer_expression+=' ohif_data_source = local.orthanc_configuration.OHIF.DataSource,'
viewer_expression+=' ohif_router_basename = local.orthanc_configuration.OHIF.RouterBasename,'
viewer_expression+=' ohif_public_path = local.ohif_public_path,'
viewer_expression+=' ohif_enabled_in_explorer = local.orthanc_configuration.OrthancExplorer2.UiOptions.EnableOpenInOhifViewer3,'
viewer_expression+=' stone_enabled_in_explorer = local.orthanc_configuration.OrthancExplorer2.UiOptions.EnableOpenInStoneWebViewer,'
viewer_expression+=' custom_css_path = local.orthanc_configuration.OrthancExplorer2.CustomCssPath,'
viewer_expression+=' built_in_instance_download = local.orthanc_configuration.OrthancExplorer2.UiOptions.EnableDownloadDicomFile,'
viewer_expression+=' instance_buttons = local.orthanc_configuration.OrthancExplorer2.UiOptions.CustomButtons.instance,'
viewer_expression+=' explorer_css = local.orthanc_explorer_css,'
viewer_expression+=' authorization_profiles = local.orthanc_configuration.Authorization.StandardConfigurations'
viewer_expression+=' })'
viewer_configuration="$({
  terraform -chdir="${project_dir}/terraform" console \
    -state="${temporary_dir}/terraform.tfstate" \
    -var-file=terraform.tfvars.example \
    -var="ssh_public_key_path=${validation_public_key}" \
    <<<"${viewer_expression}"
} | jq -r)"

jq -e '
  .ohif_data_source == "dicom-web" and
  .ohif_router_basename == "/orthanc/ohif/" and
  .ohif_public_path == "/orthanc/ohif/" and
  .ohif_enabled_in_explorer == true and
  .stone_enabled_in_explorer == true and
  .custom_css_path == "/etc/orthanc-explorer/custom.css" and
  .built_in_instance_download == false and
  (.explorer_css | contains("bi-binoculars")) and
  (.instance_buttons | length == 2) and
  (.instance_buttons | any(
    .Id == "instance-preview" and
    .Url == "../../instances/{UUID}/preview?token={study-resource-token/download-instant-link}"
  )) and
  (.instance_buttons | any(
    .Id == "instance-download" and
    .Url == "../../instances/{UUID}/file?token={study-resource-token/download-instant-link}"
  )) and
  (.authorization_profiles | index("orthanc-explorer-2") != null) and
  (.authorization_profiles | index("stone-webviewer") != null) and
  (.authorization_profiles | index("ohif") != null)
' <<<"${viewer_configuration}" >/dev/null

printf 'Viewers and instance actions share the authenticated, study-scoped token configuration.\n'
