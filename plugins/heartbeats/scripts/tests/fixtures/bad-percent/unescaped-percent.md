---
name: example-percent-unit
cron: 15 3 * * *
command: /usr/local/bin/example-job --threshold 50%
log: /var/log/example/percent-unit.log
enabled: true
---
crontab(5) reads an unescaped `%` as newline-plus-stdin, so this command would
silently run as `--threshold 50` with the remainder fed to it as input. The
parser must refuse the file rather than rewrite the operator's command line.
