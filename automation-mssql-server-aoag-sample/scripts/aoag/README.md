# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# Availability Group Automation

This folder contains the database and availability-group automation phase:

1. Create or restore demo databases on SQL1.
2. Back up full and transaction-log files.
3. Restore the databases on SQL2 with `NORECOVERY`.
4. Create or join the availability group.
5. Create and verify the native availability group listener.

The Terraform bootstrap now runs these stages automatically on SQL1 after the
WSFC and database restore stages:

- `04-prepare-sample-database.ps1` restores the configured database online on
  SQL1 and with `NORECOVERY` on SQL2.
- `05-configure-availability-group.ps1` creates the configured HADR endpoint on
  both SQL nodes, creates the configured AG with manual backup/restore seeding
  and synchronous automatic failover,
  joins SQL2, attaches the already-restored database to the AG, waits for
  online/synchronized/healthy replicas, then enables automatic failover and
  creates the configured native listener.

The script writes `TASK_5_4_AVAILABILITY_GROUP_READY.txt` after replica
synchronization and `TASK_5_5_LISTENER_READY.txt` after the listener and both
listener IPs are verified. The listener is created by SQL1 after Task 5.4;
SQL2 receives the same readiness marker over Kerberos.

For failover testing, run the guarded planned-failover script on the target
secondary only after both replicas are synchronized:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\AOAGAutomation\WSFC\06-safe-planned-failover.ps1
```

The script waits up to 30 minutes for the target secondary to be connected,
online, synchronized, healthy, and not suspended before it performs a planned
failover. Do not test failover by stopping the primary VM; that is an unplanned
failover and can leave the former primary in the documented `REVERTING` state
while it performs undo-of-redo recovery. Once the former primary returns, wait
for it to become synchronized again and run the same guarded script there to
fail back safely.

Each SQL node also registers `07-reconcile-availability-group.ps1` as a startup
task. It starts the local cluster service if needed, clears a lab-node
quarantine after a reboot, and waits for the local AG database to be
`ONLINE / SYNCHRONIZED / HEALTHY`; the primary creates the listener if needed
and both nodes verify its name, port, and IPs before writing
`AG_RECONCILIATION_READY.txt`. It never restores, recovers, drops, or rebuilds
the database, so it does not replace the AG's normal synchronization process.
