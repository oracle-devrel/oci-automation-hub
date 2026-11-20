#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-ssh-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
mkdir -p "${temporary_dir}/bin" "${temporary_dir}/home"
touch "${temporary_dir}/private-key"

file_mode() {
  local path="$1"
  local mode

  if mode="$(stat -c '%a' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -f '%Lp' "${path}"
  fi
}

cat >"${temporary_dir}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"output -raw bastion_public_ip"*) printf '%s\n' '192.0.2.10' ;;
  *"output -json resource_ocids"*) printf '%s\n' '{"bastion":"ocid1.instance.test.bastion"}' ;;
  *) exit 1 ;;
esac
STUB
cat >"${temporary_dir}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SSH_TEST_LOG}"
STUB
chmod 700 "${temporary_dir}/bin/terraform" "${temporary_dir}/bin/ssh"

for _ in 1 2; do
  HOME="${temporary_dir}/home" \
  PATH="${temporary_dir}/bin:${PATH}" \
  SSH_TEST_LOG="${temporary_dir}/ssh.log" \
  "${project_dir}/scripts/ssh-bastion.sh" \
    --private-key "${temporary_dir}/private-key" true
done

known_hosts="${temporary_dir}/home/.ssh/oci-dicom-known-hosts"
test -f "${known_hosts}"
test "$(file_mode "${known_hosts}")" = "600"
test "$(wc -l <"${temporary_dir}/ssh.log" | tr -d ' ')" = "2"
grep -Fq "UserKnownHostsFile=${known_hosts}" "${temporary_dir}/ssh.log"
grep -Fq 'HostKeyAlias=oci-dicom-ocid1.instance.test.bastion' "${temporary_dir}/ssh.log"

for stat_style in gnu bsd; do
  mkdir -p "${temporary_dir}/${stat_style}-bin"
  cat >"${temporary_dir}/${stat_style}-bin/stat" <<STUB
#!/usr/bin/env bash
if [[ "${stat_style}" == "gnu" && "\$1" == "-c" ]] ||
   [[ "${stat_style}" == "bsd" && "\$1" == "-f" ]]; then
  printf '600\\n'
  exit 0
fi
exit 1
STUB
  chmod 700 "${temporary_dir}/${stat_style}-bin/stat"
  test "$(PATH="${temporary_dir}/${stat_style}-bin:${PATH}" file_mode "${known_hosts}")" = "600"
done

printf 'Bastion SSH trust is persistent and pinned to the instance OCID.\n'
