terraform {
  required_providers {
    oci = {
      source                = "oracle/oci"
      configuration_aliases = [oci.home]
    }
  }
}
