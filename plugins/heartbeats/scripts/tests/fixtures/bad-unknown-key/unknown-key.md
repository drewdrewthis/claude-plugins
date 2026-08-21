---
name: example-unknown-key-unit
cron: 0 2 * * *
command: /usr/local/bin/example-job
log: /var/log/example/unknown-key-unit.log
enabled: true
retries: 3
---
`retries` is not a field this plugin implements. Accepting it silently would
tell the operator a retry policy is in force when nothing reads it.
