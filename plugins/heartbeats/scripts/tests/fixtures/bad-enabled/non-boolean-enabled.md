---
name: example-non-boolean-enabled-unit
cron: 0 5 * * *
command: /usr/local/bin/example-job
log: /var/log/example/non-boolean-enabled.log
enabled: yes
---
Synthetic fixture. `enabled` is `yes`, not `true` or `false`. Accepting a
YAML-ish truthy spelling here would make the difference between a job that runs
and a job that does not turn on a guess.
