# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "time_sleep" "await_operator_iam" {
  count = (
    var.litellm_install &&
    var.create_iam_resources &&
    contains(["always", "auto"], var.create_iam_operator_policy)
  ) ? 1 : 0

  create_duration  = "30s"
  destroy_duration = "0s"
}
