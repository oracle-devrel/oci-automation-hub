# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# compartment_ocid = "ocid1.compartment.oc1..aaaaaaaakkatmqsrm7x3xkkg6kgqgogubi45jgehk4laekztfdvkkmzmzdzq" # /root/ddinu


# vcn
cidr_blocks      = ["10.0.0.0/16", ]
vcn_display_name = "oke-vcn"

# subnets
api_endpoint_subnet_cidr = "10.0.1.0/24"
lb_subnet_cidr           = "10.0.2.0/24"
nodepool_subnet_cidr     = "10.0.3.0/24"
pods_subnet_cidr         = "10.0.4.0/24"