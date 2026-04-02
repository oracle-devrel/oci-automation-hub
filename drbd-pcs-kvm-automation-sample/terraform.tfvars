# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# Regions
region1 = "us-ashburn-1"
region2 = "us-phoenix-1"

# Network - Region 1
vcn_params_region1 = {
  vcn-iad = {
    vcn_cidr         = "15.0.0.0/16"
    display_name     = "vcn-iad"
    dns_label        = "vcniad"
  }
}

igw_params_region1 = {
  vcn-igw-iad = {
    display_name = "vcn-igw-iad"
    vcn_name     = "vcn-iad"
  }
}

ngw_params_region1 = {
  ngw = {
    vcn_name     = "vcn-iad"
    display_name = "ngw"
  }
}

sgw_params_region1 = {
  sgw = {
    vcn_name     = "vcn-iad"
    display_name = "sgw"
    service_name = "ALL"
  }
}

subnet_params_region1 = {
  private_subnet = {
    display_name      = "private_subnet"
    cidr_block        = "15.0.0.0/17"
    dns_label         = "privatesubnet"
    is_subnet_private = false
    sl_name           = "private_sl"
    rt_name           = "private_rt"
    vcn_name          = "vcn-iad"
  }
  public_subnet = {
    display_name      = "public_subnet"
    cidr_block        = "15.0.128.0/17"
    dns_label         = "publicsubnet"
    is_subnet_private = false
    sl_name           = "public_sl"
    rt_name           = "public_rt"
    vcn_name          = "vcn-iad"
  }
}

rt_params_region1 = {
  public_rt = {
    vcn_name     = "vcn-iad"
    display_name = "public_rt"
    route_rules = [
      {
        destination = "0.0.0.0/0"
        use_igw     = true
        igw_name    = "vcn-igw-iad"
        use_sgw     = false
        sgw_name    = ""
        ngw_name    = ""
      }
    ]
  }
  private_rt = {
    vcn_name     = "vcn-iad"
    display_name = "private_rt"
    route_rules = [
      {
        destination = "all-iad-services-in-oracle-services-network"
        use_igw     = false
        igw_name    = ""
        use_sgw     = true
        sgw_name    = "sgw"
        ngw_name    = ""
      },
      {
        destination = "0.0.0.0/0"
        use_igw     = false
        igw_name    = ""
        use_sgw     = false
        sgw_name    = ""
        ngw_name    = "ngw"
      },
    ]
  }
}

sl_params_region1 = {
  private_sl = {
    vcn_name     = "vcn-iad"
    display_name = "private_sl"
    egress_rules = [
      {
        stateless   = false
        protocol    = "all"
        destination = "0.0.0.0/0"
      },
      {
        stateless        = false
        protocol         = "all"
        destination      = "all-iad-services-in-oracle-services-network"
        destination_type = "SERVICE_CIDR_BLOCK"
      }
    ]
    ingress_rules = [
      {
        stateless   = false
        protocol    = "all"
        source      = "15.0.0.0/16"
        source_type = "CIDR_BLOCK"
        tcp_options = []
        udp_options = []
      },
      {
        stateless   = false
        protocol    = "all"
        source      = "20.0.0.0/16"
        source_type = "CIDR_BLOCK"
        tcp_options = []
        udp_options = []
      }
    ]
  }
  public_sl = {
    vcn_name     = "vcn-iad"
    display_name = "public_sl"
    egress_rules = [
      {
        stateless   = false
        protocol    = "all"
        destination = "0.0.0.0/0"
      }
    ]
    ingress_rules = [
      {
        stateless   = false
        protocol    = "all"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_options = []
        udp_options = []
      },
    ]
  }
}

drg_params_region1 = {
  drgregion1 = {
    name     = "drgregion1"
    vcn_name = "vcn-iad"
  }
}

drg_attachment_params_region1 = {
  region1-vcn-attachment = {
    drg_name = "drgregion1"
    vcn_name = "vcn-iad"
    cidr_rt  = ["20.0.0.0/16"]
    rt_names = ["public_rt", "private_rt"]
  }
}

# Network - Region2
vcn_params_region2 = {
  vcn-phx = {
    vcn_cidr         = "20.0.0.0/16"

    display_name     = "vcn-phx"
    dns_label        = "vcnphx"
  }
}

igw_params_region2 = {
  vcn-igw-phx = {
    display_name = "vcn-igw-phx"
    vcn_name     = "vcn-phx"
  }
}

ngw_params_region2 = {
  ngw = {
    vcn_name     = "vcn-phx"
    display_name = "ngw"
  }
}

sgw_params_region2 = {
  sgw = {
    vcn_name     = "vcn-phx"
    display_name = "sgw"
    service_name = "ALL"
  }
}

subnet_params_region2 = {
  private_subnet = {
    display_name      = "private_subnet"
    cidr_block        = "20.0.0.0/17"
    dns_label         = "privatesubnet"
    is_subnet_private = false
    sl_name           = "private_sl"
    rt_name           = "private_rt"
    vcn_name          = "vcn-phx"
  }
  public_subnet = {
    display_name      = "public_subnet"
    cidr_block        = "20.0.128.0/17"
    dns_label         = "publicsubnet"
    is_subnet_private = false
    sl_name           = "public_sl"
    rt_name           = "public_rt"
    vcn_name          = "vcn-phx"
  }
}

rt_params_region2 = {
  public_rt = {
    vcn_name     = "vcn-phx"
    display_name = "public_rt"
    route_rules = [
      {
        destination = "0.0.0.0/0"
        use_igw     = true
        igw_name    = "vcn-igw-phx"
        use_sgw     = false
        sgw_name    = ""
        ngw_name    = ""
      }
    ]
  }
  private_rt = {
    vcn_name     = "vcn-phx"
    display_name = "private_rt"
    route_rules = [
      {
        destination = "all-phx-services-in-oracle-services-network"
        use_igw     = false
        igw_name    = ""
        use_sgw     = true
        sgw_name    = "sgw"
        ngw_name    = ""
      },
      {
        destination = "0.0.0.0/0"
        use_igw     = false
        igw_name    = ""
        use_sgw     = false
        sgw_name    = ""
        ngw_name    = "ngw"
      },
    ]
  }
}

sl_params_region2 = {
  private_sl = {
    vcn_name     = "vcn-phx"
    display_name = "private_sl"
    egress_rules = [
      {
        stateless   = false
        protocol    = "all"
        destination = "0.0.0.0/0"
      },
      {
        stateless        = false
        protocol         = "all"
        destination      = "all-phx-services-in-oracle-services-network"
        destination_type = "SERVICE_CIDR_BLOCK"
      }
    ]
    ingress_rules = [
      {
        stateless   = false
        protocol    = "all"
        source      = "15.0.0.0/16"
        source_type = "CIDR_BLOCK"
        tcp_options = []
        udp_options = []
      },
      {
        stateless   = false
        protocol    = "all"
        source      = "20.0.0.0/16"
        source_type = "CIDR_BLOCK"
        tcp_options = []
        udp_options = []
      }
    ]
  }
  public_sl = {
    vcn_name     = "vcn-phx"
    display_name = "public_sl"
    egress_rules = [
      {
        stateless   = false
        protocol    = "all"
        destination = "0.0.0.0/0"
      }
    ]
    ingress_rules = [
      {
        stateless   = false
        protocol    = "all"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_options = []
        udp_options = []
      },
    ]
  }
}

drg_params_region2 = {
  drgregion2 = {
    name     = "drgregion2"
    vcn_name = "vcn-phx"
  }
}

drg_attachment_params_region2 = {
  region1-vcn-attachment = {
    drg_name = "drgregion2"
    vcn_name = "vcn-phx"
    cidr_rt  = ["15.0.0.0/16"]
    rt_names = ["public_rt", "private_rt"]
  }
}


# Remote Peering
requestor_params = {
  drg_name         = "drgregion1"
}

acceptor_params = {
  drg_name         = "drgregion2"
}

# DNS Region 1
dns_params_region1 = {
  dns-drbd-region1 = {
    vcn_name         = "vcn-iad"
    zone_name        = "drbddemo.com"
    zone_type        = "PRIMARY"
    zone_scope       = "PRIVATE"
    freeform_tags    = {}
    dns_view         = "DEFAULT"
  }
}

# Instances region1
instance_params_region1 = {
  host-bastion-iad = { # iSCSI Target - active
    ad                   = 1
    shape                = "VM.Standard.E6.Flex"
    hostname             = "host-bastion-iad"
    boot_volume_size     = 50
    preserve_boot_volume = false
    assign_public_ip     = true
    subnet_name          = "public_subnet"
    device_disk_mappings = ""
    freeform_tags        = {
      role = "bastion"
    }
    block_vol_att_type   = "iscsi"
    encrypt_in_transit   = true
    fd                   = 1
    image_version        = "oel9"
    ocpus                = 1
    memory_in_gbs        = 4
  }
  host-a1-iad = { # iSCSI Target - active
    ad                   = 1
    shape                = "VM.Standard.E5.Flex"
    hostname             = "host-a1-iad"
    boot_volume_size     = 50
    preserve_boot_volume = false
    assign_public_ip     = false
    subnet_name          = "private_subnet"
    device_disk_mappings = "/demobv:/dev/mapper/mpatha"
    freeform_tags        = {
      role      = "drbd"
      drbd_role = "primary"
      pcs_role  = "primary"
      kvm_role  = "primary"
    }
    block_vol_att_type   = "iscsi"
    encrypt_in_transit   = true
    fd                   = 1
    image_version        = "oel9"
    ocpus                = 16
    memory_in_gbs        = 32
  }
  host-a2-iad = { # iSCSI Target - standby
    ad                   = 2
    shape                = "VM.Standard.E5.Flex"
    hostname             = "host-a2-iad"
    boot_volume_size     = 50
    preserve_boot_volume = false
    assign_public_ip     = false
    subnet_name          = "private_subnet"
    device_disk_mappings = "/demobv:/dev/mapper/mpatha"
    freeform_tags        = {
      role = "drbd"
    }
    kms_key_name         = ""
    block_vol_att_type   = "iscsi"
    encrypt_in_transit   = true
    fd                   = 1
    image_version        = "oel9"
    ocpus                = 16
    memory_in_gbs        = 32
  }
}

bv_params_region1 = {
  abvhost = {
    ad                 = 1
    display_name       = "abvhost"
    bv_size            = 500
    instance_name      = "host-a1-iad"
    device_name        = "/dev/oracleoci/oraclevdb"
    freeform_tags      = {}
    kms_key_name       = ""
    vpus_per_gb        = 120
    encrypt_in_transit = true
  }
  bbvhost = {
    ad                 = 2
    display_name       = "bbvhost"
    bv_size            = 500
    instance_name      = "host-a2-iad"
    device_name        = "/dev/oracleoci/oraclevdb"
    freeform_tags      = {}
    kms_key_name       = ""
    vpus_per_gb        = 120
    encrypt_in_transit = true
  }
}

# Instances region2
instance_params_region2 = {
  host-b1-phx = { # iSCSI Target - active
    ad                   = 1
    shape                = "VM.Standard.E5.Flex"
    hostname             = "host-b1-phx"
    boot_volume_size     = 50
    preserve_boot_volume = false
    assign_public_ip     = false
    subnet_name          = "private_subnet"
    device_disk_mappings = "/demobv:/dev/mapper/mpatha"
    freeform_tags        = {
      role = "drbd"
    }
    block_vol_att_type   = "iscsi"
    encrypt_in_transit   = true
    fd                   = 3
    image_version        = "oel9"
    ocpus                = 16
    memory_in_gbs        = 32
  }
  host-b2-phx = { # iSCSI Target - standby
    ad                   = 2
    shape                = "VM.Standard.E5.Flex"
    hostname             = "host-b2-phx"
    boot_volume_size     = 50
    preserve_boot_volume = false
    assign_public_ip     = false
    subnet_name          = "private_subnet"
    device_disk_mappings = "/demobv:/dev/mapper/mpatha"
    freeform_tags        = {
      role = "drbd"
    }
    kms_key_name         = ""
    block_vol_att_type   = "iscsi"
    encrypt_in_transit   = true
    fd                   = 2
    image_version        = "oel9"
    ocpus                = 16
    memory_in_gbs        = 32
  }
}

bv_params_region2 = {
  cbvhost = {
    ad                 = 1
    display_name       = "cbvhost"
    bv_size            = 500
    instance_name      = "host-b1-phx"
    device_name        = "/dev/oracleoci/oraclevdb"
    freeform_tags      = {}
    kms_key_name       = ""
    vpus_per_gb        = 120
    encrypt_in_transit = true
  }
  dbvhost = {
    ad                 = 2
    display_name       = "dbvhost"
    bv_size            = 500
    instance_name      = "host-b2-phx"
    device_name        = "/dev/oracleoci/oraclevdb"
    freeform_tags      = {}
    kms_key_name       = ""
    vpus_per_gb        = 120
    encrypt_in_transit = true
  }
}

# Linux Images by region
linux_images = {
  us-ashburn-1 = {
    oel9 = "ocid1.image.oc1.iad.aaaaaaaa7r5ajr4u4djesedf6yjj2wiurnvicwtaqea6yc3oat6p6besqxpq"
  }
  us-phoenix-1 = {
    oel9 = "ocid1.image.oc1.phx.aaaaaaaakz6onguwlrq2s6mmofafxgzm64g2jdbv4zyk2nx2irq6o54u2yya"
  }
}

# PCS DRBD DNS Details
pcs_drbd_dns_details = {
  dns_object_name = "dns-drbd-region1"
  dns_record_name = "drbd"
  dns_region      = "us-ashburn-1"
}

# Linbit details
linbit_username   = ""
linbit_password   = ""
linbit_cluster_id = ""
pcs_password      = ""
