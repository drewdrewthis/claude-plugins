---
name: example-duplicated-unit
cron: 0 19 * * *
command: /usr/local/bin/example-job --second
log: /var/log/example/duplicated-unit.log
enabled: true
---
The same unit name in a second file. The name is the drift-detection key, so
two files claiming it makes every per-unit drift report ambiguous. Both files
are named in the error; neither is silently preferred.
