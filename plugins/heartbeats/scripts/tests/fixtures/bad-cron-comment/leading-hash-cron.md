---
name: example-hash-cron
cron: #30 6 * * *
command: /usr/local/bin/example-job --flag
log: /var/log/example/hash-cron.log
enabled: true
---
Synthetic fixture: `cron` starts with `#`. That is still five whitespace-
separated fields, so it passes the arity check, but it renders a line crontab(5)
reads as a comment -- an enabled unit that would install "successfully", pass
drift-check, and never fire. Deliberately unquoted: the frontmatter reader is a
strict line reader, not YAML, so quotes would be part of the value.
