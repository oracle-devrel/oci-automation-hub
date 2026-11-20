#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-generator-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

metadata="$("${project_dir}/scripts/generate-test-dicom.py" \
  "${temporary_dir}/synthetic.dcm" --patient-id SYNTHETIC-UNIT-TEST)"
jq -e '
  .PatientID == "SYNTHETIC-UNIT-TEST" and
  (.StudyInstanceUID | startswith("2.25.")) and
  (.SeriesInstanceUID | startswith("2.25.")) and
  (.SOPInstanceUID | startswith("2.25."))
' <<<"${metadata}" >/dev/null

magic="$(LC_ALL=C od -An -t x1 -j 128 -N 4 "${temporary_dir}/synthetic.dcm" | tr -d ' \n')"
[[ "${magic}" == "4449434d" ]] || {
  printf 'Generated file has invalid Part 10 magic: %s\n' "${magic}" >&2
  exit 1
}
grep -a -q 'CODEX\^SYNTHETIC' "${temporary_dir}/synthetic.dcm"
printf 'Synthetic DICOM generator emits deterministic test metadata and Part 10 data.\n'
