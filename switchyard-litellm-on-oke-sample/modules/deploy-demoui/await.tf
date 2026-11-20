# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "time_sleep" "await_demoui_lb" {
  count = local.demoui_lb_enabled ? 1 : 0

  create_duration = "90s"

  triggers = {
    deployment_id = null_resource.demoui[0].id
  }
}
