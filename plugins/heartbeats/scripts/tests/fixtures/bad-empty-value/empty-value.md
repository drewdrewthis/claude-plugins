---
name: example-empty-value-unit
cron: 0 2 * * *
command: /usr/local/bin/example-job
log:
enabled: true
---
An empty `log` would render `>> 2>&1`, which is not the redirect the operator
wrote and not a syntax cron will run.
