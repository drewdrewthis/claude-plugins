---
name: example-half-suspended
cron: 45 3 * * *
command: /usr/local/bin/example-job --flag
log: /var/log/example/half-suspended.log
enabled: false
suspension_reason: paused while the downstream consumer is rewritten
---
Synthetic fixture: `enabled: false` without `restore_condition`. A suspension
with no restore condition is how a job stays off forever by accident, so it is
rejected rather than defaulted.
