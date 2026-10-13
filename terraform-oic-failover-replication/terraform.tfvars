tenancy_ocid     = "//TODO//"
user_ocid        = "//TODO//"
fingerprint      = "//TODO//"
private_key_path = "//TODO//"

# Set primary_region and secondary_region to the OCI regions for this deployment.
tenancy_home_region  = "//TODO//"
primary_region       = "//TODO//"
secondary_region     = "//TODO//"
compartment_id     = "//TODO//"
identity_domain_id = "//TODO//"

vcn_cidr              = "10.0.0.0/16"
public_subnet_cidr    = "10.0.1.0/24"
functions_subnet_cidr = "10.0.2.0/24"

oic_dr_replication_schedule_start_time = null

primary_oic_display_name      = "test-primary-r"
oic_integration_instance_type = "STANDARDX"
oic_shape                     = "PRODUCTION"
oic_is_byol                   = false
oic_message_packs             = 1
oic_defined_tags              = {}
oic_freeform_tags             = {}

secondary_oic_display_name              = "test-secondary-r"
secondary_oic_integration_instance_type = "STANDARDX"
secondary_oic_shape                     = "DEVELOPMENT"
secondary_oic_is_byol                   = false
secondary_oic_message_packs             = 1
secondary_oic_defined_tags              = {}
secondary_oic_freeform_tags             = {}

steering_policy_display_name      = "test-steering-policy"
domain_hostname                   = "//TODO//"
dns_zone_scope                    = "GLOBAL"
dns_zone_type                     = "PRIMARY"
primary_create_functions_subnet   = false
secondary_create_functions_subnet = true

ssl_certificate_file_path    = "ssl/server-certificate.pem"
ssl_ca_certificate_file_path = "ssl/ca-chain.pem"
ssl_private_key_file_path    = "ssl/private-key.pem"

primary_client_app_display_name   = "oic-rest-client-primary"
secondary_client_app_display_name = "oic-rest-client-secondary"
client_app_description            = "Confidential application for machine-to-machine authentication to Oracle Integration Cloud (OIC), enabling secure OAuth 2.0 token acquisition and authorized access to OIC REST APIs."
client_allowed_scope_fqs          = []
client_access_token_expiry        = 3600
client_refresh_token_expiry       = 86400
client_bypass_consent             = true
client_trust_scope                = "Explicit"
client_active                     = true
