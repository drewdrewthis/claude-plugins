---
name: example-duplicate-key-unit
cron: 0 2 * * *
command: /usr/local/bin/example-job
cron: 30 9 * * *
log: /var/log/example/duplicate-key-unit.log
enabled: true
---
Two `cron` fields. Last-wins or first-wins are both a guess about which
schedule the operator meant, and the wrong guess runs a real job at the wrong
time.
