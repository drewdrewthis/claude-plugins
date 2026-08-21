---
name: example-duplicated-unit
cron: 0 7 * * *
command: /usr/local/bin/example-job --first
log: /var/log/example/duplicated-unit.log
enabled: true
---
The first file to claim this unit name.
