---
name: example-hourly-probe
cron: 0 * * * *
command: /usr/local/bin/example-probe --quiet
log: /var/log/example/hourly-probe.log
enabled: true
---
Synthetic fixture living in a SECOND units directory. It exists to prove the
units directory is a runtime input: the same script run against this directory
must render this unit and none of `units-basic`'s.
