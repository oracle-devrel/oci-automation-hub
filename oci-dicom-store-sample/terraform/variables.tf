# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "tenancy_id" {
  description = "Tenancy OCID. Required for the least-privilege Orthanc service identity."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_id))
    error_message = "tenancy_id must be a tenancy OCID."
  }
}

variable "compartment_id" {
  description = "Compartment OCID in which the DICOM platform resources are created."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.(compartment|tenancy)\\.", var.compartment_id))
    error_message = "compartment_id must be a compartment or tenancy OCID."
  }
}

variable "region" {
  description = "OCI region identifier for the workload, for example eu-frankfurt-1."
  type        = string
}

variable "home_region" {
  description = "OCI tenancy home region. IAM writes must be sent to this region."
  type        = string
}

variable "oci_profile" {
  description = "Profile in ~/.oci/config used for APIKey or SecurityToken authentication."
  type        = string
  default     = "DEFAULT"
}

variable "oci_auth" {
  description = "OCI provider authentication mode."
  type        = string
  default     = "APIKey"

  validation {
    condition = contains([
      "APIKey",
      "SecurityToken",
      "InstancePrincipal",
      "ResourcePrincipal",
      "OKEWorkloadIdentity",
    ], var.oci_auth)
    error_message = "oci_auth must be a supported OCI Terraform provider auth mode."
  }
}

variable "name" {
  description = "Short lowercase deployment name used in resource names."
  type        = string
  default     = "dicom"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name))
    error_message = "name must be 3-20 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "vcn_cidr" {
  description = "Non-overlapping VCN CIDR."
  type        = string
  default     = "10.42.0.0/16"
}

variable "gateway_subnet_cidr" {
  description = "Regional public subnet used by API Gateway."
  type        = string
  default     = "10.42.0.0/24"
}

variable "management_subnet_cidr" {
  description = "Regional public subnet used only by the bastion VM."
  type        = string
  default     = "10.42.1.0/24"
}

variable "application_subnet_cidr" {
  description = "Regional private subnet used by the OKE-created internal Network Load Balancer."
  type        = string
  default     = "10.42.10.0/24"
}

variable "oke_api_subnet_cidr" {
  description = "Regional private subnet for the OKE Kubernetes API endpoint."
  type        = string
  default     = "10.42.2.0/28"
}

variable "oke_nodes_subnet_cidr" {
  description = "Regional private subnet for OKE worker-node VNICs."
  type        = string
  default     = "10.42.11.0/24"
}

variable "oke_pods_subnet_cidr" {
  description = "Regional private subnet for VCN-native OKE pod VNICs."
  type        = string
  default     = "10.42.12.0/22"
}

variable "oke_services_cidr" {
  description = "Kubernetes Service CIDR; it must not overlap the VCN or connected networks."
  type        = string
  default     = "10.96.0.0/16"
}

variable "database_subnet_cidr" {
  description = "Regional private subnet for OCI Database with PostgreSQL."
  type        = string
  default     = "10.42.20.0/24"
}

variable "allowed_client_cidrs" {
  description = "CIDRs allowed to connect to the public API Gateway. Use hospital/VPN egress CIDRs in production."
  type        = list(string)

  validation {
    condition = length(var.allowed_client_cidrs) > 0 && alltrue([
      for cidr in var.allowed_client_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "At least one valid allowed client CIDR is required."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the OpenSSH public key installed for the bastion opc user."
  type        = string
  default     = "~/.ssh/id_rsa.pub"

  validation {
    condition = try(
      fileexists(pathexpand(var.ssh_public_key_path)) &&
      can(regex(
        "^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521))\\s+",
        trimspace(file(pathexpand(var.ssh_public_key_path))),
      )),
      false,
    )
    error_message = "ssh_public_key_path must reference an existing valid OpenSSH public key file."
  }
}

variable "bastion_allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH to the bastion. Defaults to allowed_client_cidrs when empty."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.bastion_allowed_ssh_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "Every bastion_allowed_ssh_cidrs entry must be a valid CIDR."
  }
}

variable "bastion_shape" {
  description = "Flexible Compute shape used by the bastion."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "bastion_ocpus" {
  description = "OCPUs assigned to the bastion."
  type        = number
  default     = 1

  validation {
    condition     = var.bastion_ocpus >= 1
    error_message = "bastion_ocpus must be at least 1."
  }
}

variable "bastion_memory_gb" {
  description = "Memory in GiB assigned to the bastion."
  type        = number
  default     = 8

  validation {
    condition     = var.bastion_memory_gb >= 8
    error_message = "bastion_memory_gb must be at least 8 GiB."
  }
}

variable "bastion_boot_volume_gb" {
  description = "Bastion boot volume size in GiB."
  type        = number
  default     = 50

  validation {
    condition     = var.bastion_boot_volume_gb >= 50
    error_message = "bastion_boot_volume_gb must be at least 50 GiB."
  }
}

variable "bastion_os_version" {
  description = "Oracle Linux major version for the bastion."
  type        = string
  default     = "9"
}

variable "enable_fastconnect" {
  description = "Create a private FastConnect partner virtual circuit and a TLS large-file ingest path."
  type        = bool
  default     = false
}

variable "fastconnect_on_premises_cidrs" {
  description = "On-premises CIDRs advertised over FastConnect and permitted to use private ingest and bastion SSH."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.fastconnect_on_premises_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "Every fastconnect_on_premises_cidrs entry must be a valid CIDR."
  }
}

variable "fastconnect_provider_service_id" {
  description = "FastConnect partner provider-service OCID supplied by OCI/provider discovery."
  type        = string
  default     = null

  validation {
    condition = (
      var.fastconnect_provider_service_id == null ||
      can(regex("^ocid1\\.providerservice\\.", var.fastconnect_provider_service_id))
    )
    error_message = "fastconnect_provider_service_id must be a provider-service OCID."
  }
}

variable "fastconnect_provider_service_key_name" {
  description = "Optional partner activation/service key obtained from the provider portal."
  type        = string
  default     = null
  sensitive   = true
}

variable "fastconnect_bandwidth_shape_name" {
  description = "Optional partner bandwidth shape, for example 1 Gbps; omit when provider-managed."
  type        = string
  default     = null
}

variable "fastconnect_customer_asn" {
  description = "Optional customer BGP ASN; omit when the partner manages BGP."
  type        = string
  default     = null

  validation {
    condition = (
      var.fastconnect_customer_asn == null ||
      try(
        tonumber(var.fastconnect_customer_asn) >= 1 &&
        tonumber(var.fastconnect_customer_asn) <= 4294967295,
        false,
      )
    )
    error_message = "fastconnect_customer_asn must be a decimal ASN between 1 and 4294967295."
  }
}

variable "fastconnect_ip_mtu" {
  description = "Layer-3 MTU for the FastConnect virtual circuit."
  type        = string
  default     = "MTU_1500"

  validation {
    condition     = contains(["MTU_1500", "MTU_9000"], var.fastconnect_ip_mtu)
    error_message = "fastconnect_ip_mtu must be MTU_1500 or MTU_9000."
  }
}

variable "fastconnect_is_bfd_enabled" {
  description = "Enable Bidirectional Forwarding Detection when supported by the provider and on-premises router."
  type        = bool
  default     = false
}

variable "fastconnect_is_transport_mode" {
  description = "Restrict the virtual circuit to IPSec-encrypted traffic. Requires a separate IPSec-over-FastConnect design."
  type        = bool
  default     = false
}

variable "orthanc_image" {
  description = "Fully qualified, pinned Orthanc Team image. Avoid floating latest tags."
  type        = string
  default     = "docker.io/orthancteam/orthanc:26.7.0"

  validation {
    condition     = can(regex("^[^/]+\\.[^/]+/.+(:[^/]+|@sha256:[a-f0-9]{64})$", var.orthanc_image))
    error_message = "orthanc_image must include a registry hostname and a tag or sha256 digest."
  }
}

variable "orthanc_auth_service_image" {
  description = "Fully qualified, pinned official Orthanc authorization-service image."
  type        = string
  default     = "docker.io/orthancteam/orthanc-auth-service:26.4.0"

  validation {
    condition     = can(regex("^[^/]+\\.[^/]+/.+(:[^/]+|@sha256:[a-f0-9]{64})$", var.orthanc_auth_service_image))
    error_message = "orthanc_auth_service_image must include a registry hostname and a tag or sha256 digest."
  }
}

variable "keycloak_image" {
  description = "Fully qualified, pinned upstream Keycloak image."
  type        = string
  default     = "quay.io/keycloak/keycloak:26.4.0"

  validation {
    condition     = can(regex("^[^/]+\\.[^/]+/.+(:[^/]+|@sha256:[a-f0-9]{64})$", var.keycloak_image))
    error_message = "keycloak_image must include a registry hostname and a tag or sha256 digest."
  }
}

variable "keycloak_admin_password" {
  description = "Optional existing Keycloak master-realm administrator password. A strong bootstrap value is generated when null."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.keycloak_admin_password == null || length(var.keycloak_admin_password) >= 16
    error_message = "keycloak_admin_password must be at least 16 characters when provided."
  }
}

variable "oci_identity_domain_sso" {
  description = "OCI IAM Identity Domains OIDC federation for Orthanc. Set to null to retain local Keycloak authentication only."
  type = object({
    identity_domain_id = string
    group_names = optional(map(string), {
      orthanc-viewer   = "Orthanc-Viewers"
      orthanc-uploader = "Orthanc-Uploaders"
      orthanc-editor   = "Orthanc-Editors"
      orthanc-admin    = "Orthanc-Administrators"
    })
  })
  default = null

  validation {
    condition = (
      var.oci_identity_domain_sso == null ||
      (
        can(regex("^ocid1\\.domain\\.", var.oci_identity_domain_sso.identity_domain_id)) &&
        toset(keys(var.oci_identity_domain_sso.group_names)) ==
        toset(["orthanc-viewer", "orthanc-uploader", "orthanc-editor", "orthanc-admin"]) &&
        alltrue([
          for group_name in values(var.oci_identity_domain_sso.group_names) :
          length(trimspace(group_name)) >= 3 &&
          length(group_name) <= 160 &&
          group_name == trimspace(group_name)
        ]) &&
        length(distinct([
          for group_name in values(var.oci_identity_domain_sso.group_names) :
          lower(group_name)
        ])) == 4
      )
    )
    error_message = "oci_identity_domain_sso must use an identity-domain OCID and define four unique, trimmed 3-160 character group names for the Orthanc roles."
  }
}

variable "nginx_image" {
  description = "Fully qualified, pinned reverse-proxy image used inside OKE."
  type        = string
  default     = "docker.io/library/nginx:1.29.4-alpine"

  validation {
    condition     = can(regex("^[^/]+\\.[^/]+/.+(:[^/]+|@sha256:[a-f0-9]{64})$", var.nginx_image))
    error_message = "nginx_image must include a registry hostname and a tag or sha256 digest."
  }
}

variable "postgres_client_image" {
  description = "Fully qualified, pinned PostgreSQL image used only by the idempotent Keycloak database bootstrap Job."
  type        = string
  default     = "docker.io/library/postgres:17.5-alpine"

  validation {
    condition     = can(regex("^[^/]+\\.[^/]+/.+(:[^/]+|@sha256:[a-f0-9]{64})$", var.postgres_client_image))
    error_message = "postgres_client_image must include a registry hostname and a tag or sha256 digest."
  }
}

variable "orthanc_replicas" {
  description = "Number of stateless Orthanc pods distributed across OKE worker nodes. At least two are required."
  type        = number
  default     = 2

  validation {
    condition     = var.orthanc_replicas >= 2 && var.orthanc_replicas <= 6
    error_message = "orthanc_replicas must be between 2 and 6 so Orthanc has no single-pod failure point."
  }
}

variable "keycloak_replicas" {
  description = "Number of Keycloak replicas sharing the managed PostgreSQL database."
  type        = number
  default     = 2

  validation {
    condition     = var.keycloak_replicas >= 2 && var.keycloak_replicas <= 6
    error_message = "keycloak_replicas must be between 2 and 6 so authentication has no single-pod failure point."
  }
}

variable "oke_kubernetes_version" {
  description = "OKE control-plane and managed-node Kubernetes version."
  type        = string
  default     = "v1.35.2"
}

variable "oke_node_shape" {
  description = "Flexible Compute shape for the OKE managed node pool."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "oke_node_count" {
  description = "Total number of OKE worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.oke_node_count >= 2 && var.oke_node_count <= 12
    error_message = "oke_node_count must be between 2 and 12."
  }
}

variable "oke_node_ocpus" {
  description = "OCPUs per OKE worker node."
  type        = number
  default     = 2
}

variable "oke_node_memory_gb" {
  description = "Memory in GiB per OKE worker node."
  type        = number
  default     = 16
}

variable "oke_node_boot_volume_gb" {
  description = "Boot volume size in GiB for each OKE worker node."
  type        = number
  default     = 80
}

variable "oke_max_pods_per_node" {
  description = "Maximum VCN-native pods per OKE worker node."
  type        = number
  default     = 31
}

variable "orthanc_aet" {
  description = "DICOM Application Entity Title."
  type        = string
  default     = "ORTHANC"

  validation {
    condition     = length(var.orthanc_aet) >= 1 && length(var.orthanc_aet) <= 16
    error_message = "A DICOM AE title must contain between 1 and 16 characters."
  }
}

variable "orthanc_username" {
  description = "Initial Keycloak user with the orthanc-admin role."
  type        = string
  default     = "orthanc-admin"
}

variable "orthanc_password" {
  description = "Optional initial Keycloak Orthanc administrator password. A strong random value is generated when null."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.orthanc_password == null || length(var.orthanc_password) >= 16
    error_message = "orthanc_password must be at least 16 characters when provided."
  }
}

variable "orthanc_tenants" {
  description = "Study-level tenants enforced by Orthanc labels. Map keys become stable role/user slugs; labels must be unique."
  type = map(object({
    display_name = string
    label        = optional(string)
  }))
  default = {
    tenant-a = {
      display_name = "Tenant A"
    }
    tenant-b = {
      display_name = "Tenant B"
    }
  }

  validation {
    condition = (
      length(var.orthanc_tenants) >= 2 &&
      alltrue([
        for tenant_key, tenant in var.orthanc_tenants :
        can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", tenant_key)) &&
        length(trimspace(tenant.display_name)) >= 3 &&
        length(tenant.display_name) <= 120 &&
        tenant.display_name == trimspace(tenant.display_name) &&
        can(regex("^[a-z][a-z0-9-]{1,62}[a-z0-9]$", coalesce(tenant.label, "tenant-${tenant_key}")))
      ]) &&
      length(distinct([
        for tenant_key, tenant in var.orthanc_tenants :
        coalesce(tenant.label, "tenant-${tenant_key}")
      ])) == length(var.orthanc_tenants) &&
      length(distinct([
        for tenant_key, tenant in var.orthanc_tenants : lower(tenant.display_name)
      ])) == length(var.orthanc_tenants)
    )
    error_message = "Define at least two tenants. Tenant keys and labels must be unique lowercase slugs; display names must be trimmed, unique, and contain 3-120 characters."
  }
}

variable "enable_tenant_test_users" {
  description = "Create one synthetic editor user per tenant for automated isolation testing. Disable after acceptance testing."
  type        = bool
  default     = false
}

variable "postgres_admin_username" {
  description = "PostgreSQL administrative username used by Orthanc."
  type        = string
  default     = "orthanc"
}

variable "postgres_admin_password" {
  description = "Optional PostgreSQL password. A strong random value is generated when null."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.postgres_admin_password == null || length(var.postgres_admin_password) >= 16
    error_message = "postgres_admin_password must be at least 16 characters when provided."
  }
}

variable "postgres_version" {
  description = "OCI Database with PostgreSQL major version."
  type        = string
  default     = "14"
}

variable "postgres_shape" {
  description = "OCI Database with PostgreSQL flexible shape."
  type        = string
  default     = "PostgreSQL.VM.Standard.E5.Flex"
}

variable "postgres_ocpus" {
  description = "OCPUs for each PostgreSQL instance."
  type        = number
  default     = 1
}

variable "postgres_memory_gb" {
  description = "Memory in GiB for each PostgreSQL instance."
  type        = number
  default     = 16
}

variable "postgres_instances" {
  description = "Node count in the managed OCI PostgreSQL DB system. At least two are required for automatic node failover."
  type        = number
  default     = 2

  validation {
    condition     = var.postgres_instances >= 2 && var.postgres_instances <= 8
    error_message = "postgres_instances must be between 2 and 8 so PostgreSQL has a replica node for automatic failover."
  }
}

variable "postgres_backup_retention_days" {
  description = "Automatic PostgreSQL backup retention."
  type        = number
  default     = 14

  validation {
    condition     = var.postgres_backup_retention_days >= 1
    error_message = "postgres_backup_retention_days must be at least 1."
  }
}

variable "postgres_backup_start" {
  description = "UTC hour and minute for daily PostgreSQL backups, in HH:MM format."
  type        = string
  default     = "02:00"

  validation {
    condition = can(regex(
      "^([01][0-9]|2[0-3]):[0-5][0-9]$",
      var.postgres_backup_start,
    ))
    error_message = "postgres_backup_start must use the OCI PostgreSQL HH:MM format, for example 02:00."
  }
}

variable "postgres_maintenance_window_start" {
  description = "UTC PostgreSQL maintenance start in uppercase DAY HH:MM format."
  type        = string
  default     = "SUN 03:00"

  validation {
    condition = can(regex(
      "^(MON|TUE|WED|THU|FRI|SAT|SUN) ([01][0-9]|2[0-3]):[0-5][0-9]$",
      var.postgres_maintenance_window_start,
    ))
    error_message = "postgres_maintenance_window_start must use OCI PostgreSQL DAY HH:MM format, for example SUN 03:00."
  }
}

variable "object_storage_bucket_name" {
  description = "Optional S3-compatible bucket name. A regionally unique suffix is added when null."
  type        = string
  default     = null

  validation {
    condition = (
      var.object_storage_bucket_name == null ||
      (
        length(var.object_storage_bucket_name) >= 3 &&
        length(var.object_storage_bucket_name) <= 63 &&
        can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.object_storage_bucket_name)) &&
        !can(regex("\\.\\.", var.object_storage_bucket_name)) &&
        !can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", var.object_storage_bucket_name))
      )
    )
    error_message = "object_storage_bucket_name must satisfy S3 DNS naming rules (3-63 lowercase letters, digits, dots, or hyphens; no adjacent dots or IP-address form)."
  }
}

variable "create_storage_customer_secret_key" {
  description = "Create a stack-managed Customer Secret Key, group membership, and bucket policy for an existing OCI IAM user selected by storage_user_email."
  type        = bool
  default     = true
}

variable "storage_user_email" {
  description = "Email address of exactly one existing OCI IAM user that will own the stack-managed Customer Secret Key."
  type        = string
  default     = null

  validation {
    condition = (
      var.storage_user_email == null ||
      can(regex(
        "^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$",
        var.storage_user_email,
      ))
    )
    error_message = "storage_user_email must be a syntactically valid email address."
  }
}

variable "storage_access_key" {
  description = "Existing OCI Customer Secret Key access key. Required when create_storage_customer_secret_key is false."
  type        = string
  default     = null
  sensitive   = true
}

variable "storage_secret_key" {
  description = "Existing OCI Customer Secret Key secret. Required when create_storage_customer_secret_key is false."
  type        = string
  default     = null
  sensitive   = true
}

variable "enable_object_versioning" {
  description = "Enable Object Storage versioning to protect images from accidental overwrite or deletion."
  type        = bool
  default     = true
}

variable "api_rate_limit_rps" {
  description = "Per-client API Gateway request rate."
  type        = number
  default     = 100
}

variable "cors_allowed_origins" {
  description = "Optional browser origins allowed by API Gateway. Leave empty for no CORS policy."
  type        = list(string)
  default     = []
}

variable "alarm_notification_topic_id" {
  description = "Optional Notifications topic OCID for API Gateway 5xx alarms."
  type        = string
  default     = null
}

variable "freeform_tags" {
  description = "Additional free-form tags applied to resources."
  type        = map(string)
  default     = {}
}

variable "enable_large_upload_endpoint" {
  description = "Create a public HTTPS NLB endpoint for DICOM uploads, restricted to allowed_client_cidrs."
  type        = bool
  default     = false
}
