#!/usr/bin/env bash
# Scaffold (same in every case): a small Python app that already runs on Postgres.
set -e
git init -q .
mkdir -p app
printf 'import psycopg\n\nDB_URL = "postgresql://localhost/acme"\n\ndef connect():\n    return psycopg.connect(DB_URL)\n' > app/db.py
printf 'def add(a, b):\n    return a + b\n' > app/calc.py
printf '# acme\n\nSmall Flask app. Runs on one VM with Postgres 16. Two developers.\n' > README.md
printf 'flask==3.0\npsycopg==3.2\n' > requirements.txt
git add -A && git -c user.email=e@x -c user.name=e commit -qm init
