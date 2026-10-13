locals {
  secondary_normalized_client_allowed_scope_fqs = [
    for scope in var.client_allowed_scope_fqs :
    can(regex("^https?://", scope))
    ? scope
    : "${trimsuffix(module.secondary_oic_instance.primary_audience_url, "/")}/${scope}"
  ]
}

# Read the Identity Domains application generated for this OIC instance so the
# matching OAuth client can request every resource scope the instance exposes.
data "oci_identity_domains_app" "secondary_oic_resource" {
  provider = oci.secondary

  idcs_endpoint = data.oci_identity_domain.this.url
  app_id        = module.secondary_oic_instance.idcs_app_id
}

locals {
  secondary_oic_resource_scope_fqs = [
    for scope in data.oci_identity_domains_app.secondary_oic_resource.scopes :
    scope.fqs
  ]
}

module "secondary_oic_instance" {
  depends_on = [oci_dns_zone.public]
  source     = "./modules/oic_instance"

  providers = {
    oci = oci.secondary
  }

  compartment_id            = var.compartment_id
  domain_id                 = var.identity_domain_id
  display_name              = coalesce(var.secondary_oic_display_name, "${var.secondary_oic_display_name}-secondary")
  integration_instance_type = var.secondary_oic_integration_instance_type
  shape                     = var.secondary_oic_shape
  is_byol                   = var.secondary_oic_is_byol
  message_packs             = var.secondary_oic_message_packs
  defined_tags              = var.secondary_oic_defined_tags
  freeform_tags             = var.secondary_oic_freeform_tags
}

# Read the certificate chain the regional OIC endpoint presents once the
# instance is available. The URL reference defers this data read until apply
# when the OIC URL is first created.
data "tls_certificate" "secondary_oic_backend" {
  depends_on = [module.secondary_oic_instance]
  url        = module.secondary_oic_instance.instance_url
}

locals {
  secondary_oic_backend_server_certificate_pem = one([
    for certificate in data.tls_certificate.secondary_oic_backend.certificates : certificate.cert_pem
    if !certificate.is_ca
  ])
  secondary_oic_backend_ca_certificate_pem = join("\n", [
    for certificate in data.tls_certificate.secondary_oic_backend.certificates : certificate.cert_pem
    if certificate.is_ca
  ])
}

data "external" "secondary_oic_dns" {
  # Waiting for the OIC resource ensures that the endpoint exists before DNS is queried.
  depends_on = [module.secondary_oic_instance]

  program = [
    "sh",
    "-c",
    <<-EOT
      ipv4=$(dig +short A "$1" | awk 'NR == 2 { print; exit }')
      printf '{"ipv4":"%s"}\n' "$ipv4"
    EOT
    ,
    "dig-oic-host",
    regex("^https?://([^/:]+)", module.secondary_oic_instance.instance_url)[0],
  ]
}

module "secondary_network" {
  depends_on = [module.secondary_oic_instance]

  source = "./modules/network"

  providers = {
    oci = oci.secondary
  }

  compartment_id        = var.compartment_id
  name_prefix           = var.secondary_oic_display_name
  vcn_cidr              = var.vcn_cidr
  public_subnet_cidr    = var.public_subnet_cidr
  functions_subnet_cidr = var.functions_subnet_cidr
  # The replication Function is deployed in the secondary region, so its VCN
  # needs a private subnet with outbound NAT access.
  create_functions_subnet = var.secondary_create_functions_subnet
  oic_host_ipv4           = data.external.secondary_oic_dns.result.ipv4
}

module "secondary_oic_load_balancer" {
  source = "./modules/oic_load_balancer"

  providers = {
    oci = oci.secondary
  }

  compartment_id                 = var.compartment_id
  subnet_id                      = module.secondary_network.public_subnet_id
  vcn_id                         = module.secondary_network.vcn_id
  backend_ip_address             = data.external.secondary_oic_dns.result.ipv4
  name_prefix                    = var.secondary_oic_display_name
  listener_certificate_id        = module.secondary_oic_certificates.certificate_id
  backend_server_certificate_pem = local.secondary_oic_backend_server_certificate_pem
  backend_ca_certificate_pem     = local.secondary_oic_backend_ca_certificate_pem
  defined_tags                   = var.secondary_oic_defined_tags
  freeform_tags                  = var.secondary_oic_freeform_tags
}

module "secondary_oic_certificates" {
  source = "./modules/oic_certificates"

  providers = {
    oci = oci.secondary
  }

  compartment_id               = var.compartment_id
  name_prefix                  = var.secondary_oic_display_name
  ssl_certificate_file_path    = var.ssl_certificate_file_path
  ssl_ca_certificate_file_path = var.ssl_ca_certificate_file_path
  ssl_private_key_file_path    = var.ssl_private_key_file_path
  defined_tags                 = var.secondary_oic_defined_tags
  freeform_tags                = var.secondary_oic_freeform_tags
}

module "secondary_oic_client_app" {
  depends_on = [module.secondary_oic_instance]
  source     = "./modules/oic_client_app"

  providers = {
    oci = oci.secondary
  }

  idcs_endpoint = data.oci_identity_domain.this.url
  display_name  = var.secondary_client_app_display_name
  description   = var.client_app_description
  allowed_scope_fqs = distinct(concat(
    local.secondary_oic_resource_scope_fqs,
    local.secondary_normalized_client_allowed_scope_fqs,
  ))
  access_token_expiry  = var.client_access_token_expiry
  refresh_token_expiry = var.client_refresh_token_expiry
  bypass_consent       = var.client_bypass_consent
  trust_scope          = var.client_trust_scope
  active               = var.client_active
}

# The secondary OIC instance has a distinct Identity Domains application and
# ServiceAdministrator role. Keep its grant scoped to the secondary OAuth
# client application.
data "oci_identity_domains_app_roles" "secondary_service_administrator" {
  provider = oci.secondary

  idcs_endpoint   = data.oci_identity_domain.this.url
  app_role_filter = "displayName eq \"ServiceAdministrator\" and app.value eq \"${module.secondary_oic_instance.idcs_app_id}\""
}

resource "oci_identity_domains_grant" "secondary_service_administrator" {
  provider = oci.secondary

  idcs_endpoint   = data.oci_identity_domain.this.url
  schemas         = ["urn:ietf:params:scim:schemas:oracle:idcs:Grant"]
  grant_mechanism = "ADMINISTRATOR_TO_APP"

  # The OIC-generated application is the server application whose AppRole is
  # being granted.
  app {
    value = module.secondary_oic_instance.idcs_app_id
  }

  entitlement {
    attribute_name  = "appRoles"
    attribute_value = one(data.oci_identity_domains_app_roles.secondary_service_administrator.app_roles).id
  }

  # The OAuth client for this OIC instance is the consuming application.
  grantee {
    type  = "App"
    value = module.secondary_oic_client_app.id
  }

  lifecycle {
    precondition {
      condition     = length(data.oci_identity_domains_app_roles.secondary_service_administrator.app_roles) == 1
      error_message = "Expected exactly one ServiceAdministrator AppRole for the secondary OIC-generated application."
    }
  }
}

# This token is scoped to the secondary OIC application and is independent
# from the primary region's OAuth client and role grant.
module "secondary_oic_bearer_token" {
  depends_on = [oci_identity_domains_grant.secondary_service_administrator]
  source     = "./modules/bearer_token"

  idcs_endpoint = data.oci_identity_domain.this.url
  client_id     = module.secondary_oic_client_app.name
  client_secret = module.secondary_oic_client_app.client_secret
  scope_fqs = distinct(concat(
    local.secondary_oic_resource_scope_fqs,
    local.secondary_normalized_client_allowed_scope_fqs,
  ))
}

module "oic_dr_replication_function" {
  source = "./modules/oic_dr_replication_function"

  providers = {
    oci      = oci.secondary
    oci.home = oci.home
  }

  compartment_id          = var.compartment_id
  tenancy_ocid            = var.tenancy_ocid
  secondary_region        = var.secondary_region
  subnet_id               = module.secondary_network.functions_subnet_id
  name_prefix             = var.secondary_oic_display_name
  primary_oic_url         = module.primary_oic_instance.instance_url
  secondary_oic_url       = module.secondary_oic_instance.instance_url
  idcs_endpoint           = data.oci_identity_domain.this.url
  primary_client_id       = module.primary_oic_client_app.name
  primary_client_secret   = module.primary_oic_client_app.client_secret
  primary_scope_fqs       = distinct(concat(local.primary_oic_resource_scope_fqs, local.primary_normalized_client_allowed_scope_fqs))
  secondary_client_id     = module.secondary_oic_client_app.name
  secondary_client_secret = module.secondary_oic_client_app.client_secret
  secondary_scope_fqs     = distinct(concat(local.secondary_oic_resource_scope_fqs, local.secondary_normalized_client_allowed_scope_fqs))
  role_grant_ids = [
    oci_identity_domains_grant.primary_service_administrator.id,
    oci_identity_domains_grant.secondary_service_administrator.id,
  ]
  schedule_start_time = var.oic_dr_replication_schedule_start_time
  freeform_tags       = var.oic_freeform_tags
}
