---
name: example-weekly-sweep
cron: 0 4 * * 0
command: /usr/local/bin/example-sweep --dry-run
log: /var/log/example/weekly-sweep.log
enabled: false
suspension_reason: upstream endpoint returns 503 during the maintenance window
restore_condition: re-enable once the upstream status page reports steady state
---
Synthetic fixture for the suspended-unit rendering path.
