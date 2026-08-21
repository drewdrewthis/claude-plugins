---
name: example-short-cron
cron: 0 5 * *
command: /usr/local/bin/example-job --flag
log: /var/log/example/short-cron.log
enabled: true
---
Synthetic fixture: `cron` has 4 fields, not 5.
