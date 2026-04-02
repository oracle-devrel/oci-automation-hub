# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

########################### NETWORK #################################

vcn_params = {
  chvcn = {
    compartment_name = "sandbox"
    display_name     = "VCNTF_ch"
    vcn_cidr         = "10.20.0.0/16"
    dns_label        = "vcntf"
  }
}

subnet_params = {
  chpub = {
    display_name      = "chpub"
    cidr_block        = "10.20.1.0/24"
    dns_label         = "VCNPUB"
    is_subnet_private = false
    sl_name           = "chsl"
    rt_name           = "chpub"
    vcn_name          = "chvcn"
  }
  chpriv = {
    display_name      = "chpriv"
    cidr_block        = "10.20.2.0/24"
    dns_label         = "ch1priv"
    is_subnet_private = true
    sl_name           = "chsl"
    rt_name           = "chpriv"
    vcn_name          = "chvcn"
  }
}

igw_params = {
  chigw = {
    display_name = "VCNIGW"
    vcn_name     = "chvcn"
  },
}

ngw_params = {
  chngw = {
    display_name = "VCNNGW"
    vcn_name     = "chvcn"
  },
}

rt_params = {
  chpub = {
    display_name = "PUB-RT"
    vcn_name     = "chvcn"

    route_rules = [
      {
        destination = "0.0.0.0/0"
        use_igw     = true
        igw_name    = "chigw"
        ngw_name    = null
      },
    ]
  },
  chpriv = {
    display_name = "PRIV-RT"
    vcn_name     = "chvcn"

    route_rules = [
      {
        destination = "0.0.0.0/0"
        use_igw     = false
        igw_name    = null
        ngw_name    = "chngw"
      },
    ]
  },
}

sl_params = {
  chsl = {
    vcn_name     = "chvcn"
    display_name = "VCN-SL"

    egress_rules = [
      {
        stateless   = "false"
        protocol    = "all"
        destination = "0.0.0.0/0"
      },
    ]

    ingress_rules = [
      {
        stateless   = "false"
        protocol    = "all"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_options = []
        udp_options = []
      },
    ]
  }
}

############################## COMPUTE ##################################

linux_images = {
  eu-frankfurt-1 = {
    oel9    = "ocid1.image.oc1.eu-frankfurt-1.aaaaaaaap6fyk44edftzyywudj4ofztrjsq7d47qtslsd74rlzlm3hu52xca" #Oracle-Linux-9.6-2025.11.20-0
  }
  us-ashburn-1 = {
    oel9    = "ocid1.image.oc1.iad.aaaaaaaaglxne5nh73mxqppl3fkzkqdlda3k22y6oyxcvy6gcaxxsym54mca"
  }
}

instance_params = {
  chvm = {
    ad                   = 1
    shape                = "VM.Standard.E5.Flex"
    hostname             = "chvm"
    boot_volume_size     = 50
    preserve_boot_volume = false
    assign_public_ip     = true
    compartment_name     = "sandbox"
    subnet_name          = "chpub"
    freeform_tags = {
      "client" : "vfo",
      "department" : "vfo"
    }
    block_vol_att_type = "iscsi"
    encrypt_in_transit = true
    fd                 = 1
    image_version      = "oel9"
    ssh_private_key    = "~/.ssh/id_rsa" ## PATH TO SSH PRIVATE KEY - CHNAGE ME
    script_tf_string   = "TEST_HUR_1"
    ocpus               = 1
    memory_in_gbs       = 16
  }
}

ssh_public_key = "~/.ssh/id_rsa.pub" ## PATH TO SSH PUBLIC KEY - CHANGE ME

kms_key_ids = {}
registry = "fra.ocir.io" ## change to registry of your choice, e.g. fra.ocir.io, iad.ocir.io, etc.