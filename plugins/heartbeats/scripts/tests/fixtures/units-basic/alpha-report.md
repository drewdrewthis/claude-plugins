---
name: example-daily-report
cron: 30 6 * * *
command: /usr/local/bin/example-job --flag
log: /var/log/example/daily-report.log
enabled: true
---
Synthetic fixture. Prose below the frontmatter is documentation and must not
reach the rendered crontab line — this paragraph is the assertion that it
doesn't.
