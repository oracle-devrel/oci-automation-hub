# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

TF_ARGS ?=
DICOM_FILE ?=
PRIVATE_KEY ?= $(HOME)/.ssh/id_rsa
TENANT ?=
STUDY_UID ?=
STUDY_ID ?=

.PHONY: \
	help init fmt validate plan show-plan apply apply-auto outputs show-output verify \
	verify-dicom verify-dicom-clean verify-compliance classify-study failure-test \
	restore-drill restore-drill-auto get-credentials configure-bastion \
	deploy-oke bastion-status destroy destroy-auto destroy-purge destroy-purge-auto

help: ## Show the available deployment commands.
	@printf '%s\n' \
		'OCI DICOM deployment targets:' \
		'' \
		'  make validate             Run Terraform, shell, JSON, and Ansible checks' \
		'  make plan                 Create terraform/dicom.tfplan without applying it' \
		'  make show-plan            Display the saved Terraform plan' \
		'  make apply                Plan and apply interactively' \
		'  make apply-auto           Plan and apply without confirmation' \
		'  make verify               Test Orthanc REST, DICOMweb, Stone, and OHIF' \
		'  make verify-compliance    Prove STOW/QIDO/WADO, tenant isolation, audit, storage, and backup policy' \
		'  make failure-test         Delete one Orthanc pod and prove uninterrupted recovery' \
		'  make restore-drill        Create a backup, restore/validate it, then remove drill resources' \
		'  make classify-study TENANT=tenant-a STUDY_UID=...  Assign the trusted tenant label' \
		'  make verify-dicom       Upload a synthetic DICOM and keep it visible in Orthanc' \
		'  make verify-dicom-clean Upload, verify, and remove a synthetic DICOM' \
		'  make verify-dicom DICOM_FILE=/absolute/test.dcm  Test a supplied DICOM instead' \
		'  make get-credentials      Display Orthanc/Keycloak credentials and URLs' \
		'  make configure-bastion    Configure the bastion with Ansible' \
		'  make deploy-oke           Apply/update Orthanc and Keycloak on OKE' \
		'  make bastion-status       Test the private stack from the bastion' \
		'  make outputs              Show the non-secret deployment summary' \
		'  make show-output          Show all Terraform outputs (secrets redacted)' \
		'  make destroy              Destroy; preserve a non-empty DICOM bucket' \
		'  make destroy-auto         Same data-preserving destroy without confirmation' \
		'  make destroy-purge        Permanently purge the bucket, then destroy' \
		'  make destroy-purge-auto   Purge and destroy without confirmation (dangerous)' \
		'' \
		'Optional overrides:' \
		'  TF_ARGS="-var=name=value" PRIVATE_KEY=/absolute/path/to/id_rsa'

init: ## Initialize Terraform providers and backend.
	terraform -chdir=terraform init

fmt: ## Format all Terraform files.
	terraform -chdir=terraform fmt -recursive

validate: ## Run all static deployment checks.
	./scripts/validate.sh

plan: ## Create a saved, state-aware Terraform plan.
	./scripts/deploy.sh --plan-only $(TF_ARGS)

show-plan: ## Display the saved Terraform plan.
	@test -f terraform/dicom.tfplan || { printf '%s\n' 'terraform/dicom.tfplan is missing; run make plan first.' >&2; exit 1; }
	terraform -chdir=terraform show dicom.tfplan

apply: ## Plan, apply interactively, and configure the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	BASTION_SSH_PRIVATE_KEY_FILE="$(PRIVATE_KEY)" ./scripts/deploy.sh $(TF_ARGS)

apply-auto: ## Plan and apply without confirmation, then configure the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	BASTION_SSH_PRIVATE_KEY_FILE="$(PRIVATE_KEY)" ./scripts/deploy.sh --auto-approve $(TF_ARGS)

outputs: ## Show the non-secret deployment summary.
	terraform -chdir=terraform output deployment_summary

show-output: ## Show all Terraform outputs with sensitive values redacted.
	terraform -chdir=terraform output

verify: ## Check public Orthanc REST, DICOMweb, Stone, and OHIF endpoints.
	./scripts/verify.sh

verify-dicom: ## Upload and retain one non-production DICOM instance.
	@set -euo pipefail; \
	if [[ -n "$(DICOM_FILE)" ]]; then \
		./scripts/verify.sh --dicom "$(DICOM_FILE)"; \
	else \
		test_dicom="$$(mktemp "$${TMPDIR:-/tmp}/oci-dicom-test.XXXXXX")"; \
		trap 'rm -f "$${test_dicom}"' EXIT; \
		./scripts/generate-test-dicom.py "$${test_dicom}"; \
		./scripts/verify.sh --dicom "$${test_dicom}"; \
	fi

verify-dicom-clean: ## Upload, verify, and remove one synthetic DICOM instance.
	@set -euo pipefail; \
	test_dicom="$$(mktemp "$${TMPDIR:-/tmp}/oci-dicom-test.XXXXXX")"; \
	trap 'rm -f "$${test_dicom}"' EXIT; \
	./scripts/generate-test-dicom.py "$${test_dicom}"; \
		./scripts/verify.sh --dicom "$${test_dicom}" --delete-after-upload

verify-compliance: ## Run the synthetic DICOMweb, tenant-isolation, audit, encryption, and backup-policy test.
	./scripts/verify-compliance.sh

classify-study: ## Assign one configured tenant label to a study as the trusted administrator.
	@test -n "$(TENANT)" || { printf '%s\n' 'Set TENANT to a configured tenant key.' >&2; exit 2; }
	@set -euo pipefail; \
	if [[ -n "$(STUDY_UID)" && -z "$(STUDY_ID)" ]]; then \
		./scripts/classify-study.sh --tenant "$(TENANT)" --study-uid "$(STUDY_UID)"; \
	elif [[ -n "$(STUDY_ID)" && -z "$(STUDY_UID)" ]]; then \
		./scripts/classify-study.sh --tenant "$(TENANT)" --study-id "$(STUDY_ID)"; \
	else \
		printf '%s\n' 'Set exactly one of STUDY_UID or STUDY_ID.' >&2; exit 2; \
	fi

failure-test: ## Delete one Orthanc pod and prove the redundant deployment remains available.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	./scripts/failure-test.sh --private-key "$(PRIVATE_KEY)"

restore-drill: ## Create/restore/validate/delete an OCI PostgreSQL backup (billable and long-running).
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	./scripts/restore-drill.sh --private-key "$(PRIVATE_KEY)"

restore-drill-auto: ## Run the billable restore drill without confirmation.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	./scripts/restore-drill.sh --private-key "$(PRIVATE_KEY)" --auto-approve

get-credentials: ## Display the Orthanc login credentials and Web UI endpoint.
	@printf 'Orthanc user (orthanc-admin role): '
	@terraform -chdir=terraform output -raw orthanc_username
	@printf '\nOrthanc user password: '
	@terraform -chdir=terraform output -raw orthanc_password
	@printf '\nOrthanc Web UI: '
	@terraform -chdir=terraform output -raw api_endpoint
	@printf '/ui/app/\nKeycloak admin user: '
	@terraform -chdir=terraform output -raw keycloak_admin_username
	@printf '\nKeycloak admin password: '
	@terraform -chdir=terraform output -raw keycloak_admin_password
	@printf '\nKeycloak admin console: '
	@terraform -chdir=terraform output -raw keycloak_endpoint
	@printf '/admin/\n'
	@terraform -chdir=terraform output -json oci_sso | jq -r '\
		if .enabled then \
		  "OCI IAM SSO: enabled\nOrthanc SSO sign-in: \(.orthanc_login_url)\nOCI role groups:\n" + \
		  (.group_names | to_entries | sort_by(.key) | map("  \(.key): \(.value)") | join("\n")) \
		else "OCI IAM SSO: disabled" end'
	@terraform -chdir=terraform output -json tenant_authorization | jq -r '\
		"Tenant authorization:\n" + \
		(.tenants | to_entries | sort_by(.key) | map("  \(.key): label=\(.value.label), groups=" + ((.value.sso_groups // {}) | values | join(", "))) | join("\n"))'
	@terraform -chdir=terraform output -json tenant_test_credentials | jq -r '\
		if length > 0 then \
		  "Synthetic acceptance users (disable after testing):\n" + \
		  (to_entries | sort_by(.key) | map("  \(.key): \(.value.username) / \(.value.password)") | join("\n")) \
		else "Synthetic acceptance users: disabled" end'

configure-bastion: ## Apply the Ansible operator configuration to the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	./scripts/configure-bastion.sh --private-key "$(PRIVATE_KEY)"

deploy-oke: ## Apply or update the Orthanc, authorization-service, and Keycloak workloads.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	./scripts/deploy-oke.sh --private-key "$(PRIVATE_KEY)"

bastion-status: ## Test private Orthanc, DICOMweb, and PostgreSQL from the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	./scripts/ssh-bastion.sh --private-key "$(PRIVATE_KEY)" sudo /usr/local/sbin/dicom-status

destroy: ## Plan and destroy the stack with confirmation.
	./scripts/destroy.sh

destroy-auto: ## Destroy the stack without confirmation.
	./scripts/destroy.sh --auto-approve

destroy-purge: ## Permanently purge the Object Storage bucket and destroy the stack.
	./scripts/destroy.sh --purge-bucket

destroy-purge-auto: ## Permanently purge and destroy without confirmation.
	./scripts/destroy.sh --purge-bucket --auto-approve
