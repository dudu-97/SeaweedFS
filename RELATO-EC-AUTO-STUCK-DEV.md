# Report: automatic EC maintenance task is correctly planned (respects configured ratio) but never executed

## Environment

- SeaweedFS Enterprise, `weed version` → `8000GB 4.45-enterprise 7032a2d3` (same build as the prior `ec.encode` ratio report).
- Cluster: 3 masters (raft) + filer (Postgres store), 1 standalone `weed s3`, 7 volume nodes (14 volume server processes), `weed admin` + `weed worker -jobType=all` both on the same host as master1.
- `ec.config -get` confirmed **`Global Default EC Ratio: 5+2`** throughout the test and at report time.
- `weed-admin` had been running for ~21h with a maintenance-threshold override already active (`/etc/systemd/system/weed-admin.service.d/override.conf`):
  ```
  WEED_MAINTENANCE_ERASURE_CODING_FULLNESS_RATIO=0.0000001
  WEED_MAINTENANCE_ERASURE_CODING_QUIET_FOR_SECONDS=10
  WEED_MAINTENANCE_ERASURE_CODING_SCAN_INTERVAL_SECONDS=15
  WEED_MAINTENANCE_ERASURE_CODING_MIN_SIZE_MB=1
  ```
  Confirmed loaded into the live process via `/proc/<pid>/environ`.

## Summary

This is a follow-up to our earlier report (`ec.encode` manual command ignoring the configured EC ratio). We wanted to confirm whether the **automatic path** (the `weed admin` maintenance scanner + `weed worker`) respects the configured ratio, since the manual shell command does not.

**Good news:** the automatic detection/planning logic does respect the configured ratio — for every volume it evaluated, it explicitly planned **7 destinations (5 data + 2 parity)**, matching `ec.config`.

**Bug:** despite being planned correctly, the resulting `erasure_coding` maintenance task is **never dispatched to / executed by the worker**. It sits in a `pending` state, gets cancelled and recreated identically on every subsequent scan, forever. Over 22h of continuous `weed-worker` uptime (with `-jobType=all`), **zero** `erasure_coding` tasks executed, while **177** `balance`/`ec_balance` tasks executed successfully in the same window — so the worker itself is healthy and does process other maintenance task types.

There's also a secondary, previously-suspected finding we can now confirm with full history: `WEED_MAINTENANCE_ERASURE_CODING_SCAN_INTERVAL_SECONDS` has no effect — the scan cadence is fixed at 30 minutes from the `weed-admin` process start time, regardless of this env var.

## Steps to reproduce

```
# 1. Confirm ratio is set
weed shell -master=<master>:9333
> ec.config -get
Global Default EC Ratio: 5+2

# 2. Lower maintenance thresholds so any small/quiet volume qualifies
#    (systemd override on weed-admin.service, or scaffold config):
Environment=WEED_MAINTENANCE_ERASURE_CODING_FULLNESS_RATIO=0.0000001
Environment=WEED_MAINTENANCE_ERASURE_CODING_QUIET_FOR_SECONDS=10
Environment=WEED_MAINTENANCE_ERASURE_CODING_MIN_SIZE_MB=1
systemctl daemon-reload && systemctl restart weed-admin

# 3. Upload any real data so at least one normal (non-EC) volume exists
#    and goes quiet (no more writes for >10s).

# 4. Wait for a maintenance scan (fixed ~30min cadence from weed-admin's
#    last restart — see "scan interval" finding below) and inspect the
#    admin log:
journalctl -u weed-admin | grep -E "EC Detection|Task queued|Cancelled.*stale pending|Maintenance scan completed"

# 5. Inspect the worker log for actual execution:
journalctl -u weed-worker | grep -c erasure_coding   # count of any erasure_coding activity
journalctl -u weed-worker | grep -cE "balance_task|ec_balance_task"   # control: other task types
```

## Evidence

**1. Detection/planning respects the configured 5+2 ratio (all 25 candidate volumes, one scan):**
```
I0906 16:43:54.486162 admin_server.go:2349 Loaded EC configuration from filer /etc/seaweedfs/ec.conf: global=5+2, 0 collection overrides
I0906 16:43:54.486288 detection.go:252 EC Detection: Volume 22 meets all criteria, attempting to create task
I0906 16:43:54.486319 detection.go:282 EC Detection: ActiveTopology available, planning destinations for volume 22 with EC ratio 5+2
I0906 16:43:54.486391 detection.go:300 EC Detection: Successfully planned 7 destinations for volume 22
... (identical "Successfully planned 7 destinations" line for all 25 volumes: 22, 45-57, 66-76)
```

**2. The resulting task is queued, but with a self-cancelling lifecycle — every scan cancels the prior batch and recreates it from scratch:**
```
I0906 16:43:54.484270 maintenance_integration.go:277 Cancelled 14 stale pending erasure_coding tasks before re-detection
I0906 16:43:54.499695 maintenance_queue.go:205 Task queued: ec_vol_22_1788713034 (erasure_coding) volume 22 on 192.168.100.52:8080, priority 0, reason: Volume meets EC criteria: quiet for 72590.5s (>10s), fullness=0.0% (>0.0%), size=5.0MB (>1MB)
... (25 such "Task queued" lines total)
I0906 16:43:54.503926 maintenance_manager.go:367 Maintenance scan completed: found 29 tasks
```
`"Cancelled N stale pending erasure_coding tasks before re-detection"` appeared **41 times** in the admin log — i.e. on almost every one of the 45 scans since the last `weed-admin` restart, confirming this cancel+recreate cycle is systematic, not a one-off.

**3. The worker never actually runs an `erasure_coding` task, despite running other task types fine:**
```
$ journalctl -u weed-worker | grep -c 'erasure_coding'
0
$ journalctl -u weed-worker | grep -cE 'balance_task|ec_balance_task'
177
```
Sample of what the worker *does* execute successfully in the same window (task types `balance` and `ec_balance`, both unrelated to the stuck `erasure_coding` type):
```
I0906 16:17:03.367418 task.go:63 Starting balance task - moving volume
I0906 16:20:19.916735 balance_task.go:91 Balance task completed successfully: volume 17 moved from 192.168.100.53:8080.18080 to 192.168.100.54:8080.18080
I0906 16:45:00.786589 ec_balance_task.go:204 EC balance volume 8: [10.00] copying EC shard(s) 8.[1] from 192.168.100.53:8081 to 192.168.100.53:8080
I0906 16:45:01.064091 ec_balance_task.go:134 EC balance: successfully moved shard(s) [1] of volume 8 from 192.168.100.53:8081 to 192.168.100.53:8080
```
Worker was started with `-jobType=all` (`/usr/local/bin/weed worker -admin=<host>:23646 -jobType=all -workingDir=/var/lib/seaweedfs/worker`), so this isn't a job-type filtering flag issue on the worker side.

**4. Scan interval env var confirmed to have no effect — 45/45 scans landed on a fixed 30-minute grid from process start (`weed-admin` last restarted `2026-09-05 20:13:52`), despite `WEED_MAINTENANCE_ERASURE_CODING_SCAN_INTERVAL_SECONDS=15`:**
```
Sep 05 20:43:54 ... Maintenance scan completed: found 6 tasks
Sep 05 21:13:54 ... Maintenance scan completed: found 12 tasks
Sep 05 21:43:54 ... Maintenance scan completed: found 11 tasks
...
Sep 06 16:43:54 ... Maintenance scan completed: found 29 tasks
Sep 06 17:13:54 ... Maintenance scan completed: found 29 tasks
```
Every timestamp is exactly `:13:54` or `:43:54`, i.e. a fixed 1800s period, never 15s.

## Impact

In a cluster relying on the automatic maintenance scheduler (rather than manually invoking `ec.encode`, which we already reported ignores the ratio too), **volumes that qualify for erasure coding never actually get encoded** — they stay in their original, unprotected replication state indefinitely, even though the dashboard/logs show the system correctly identifying them as candidates and correctly planning a 5+2 layout for them. This is a silent failure: there's no error, just an endless detect → plan → queue → cancel → re-detect loop.

