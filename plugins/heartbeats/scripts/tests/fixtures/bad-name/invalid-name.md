---
name: example bad name
cron: 0 5 * * *
command: /usr/local/bin/example-job
log: /var/log/example/bad-name.log
enabled: true
---
Synthetic fixture. The unit name contains spaces, so it cannot round-trip
through the `# heartbeats-unit: <name>` header line — the header would parse
back as a different name than the one declared here.
