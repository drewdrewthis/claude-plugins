---
name: example-broken-unit
cron: 0 5 * * *
command: /usr/local/bin/example-job
log: /var/log/example/broken.log
enabled: true

Synthetic fixture: the frontmatter block is never closed, so there is no
boundary between fields and prose and nothing here can be read as a unit.
