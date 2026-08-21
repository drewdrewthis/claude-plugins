---
name: example-percent-cron-unit
cron: 0 5 * * %
command: /usr/local/bin/example-job
log: /var/log/example/percent-cron.log
enabled: true
---
Synthetic fixture. The schedule carries an unescaped `%`. It has the right
shape (five whitespace-separated fields) so the arity check passes, which is
exactly why the percent check has to cover `cron` too: this value would be
written verbatim onto the live crontab line.
