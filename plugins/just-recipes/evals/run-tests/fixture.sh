#!/usr/bin/env bash
# Shared scaffold: a small git repo whose justfile already has the common tasks.
set -e
git init -q .
mkdir -p src
printf 'def add(a, b):\n    return a + b  # TODO: handle None\n' > src/calc.py
printf 'from calc import add\n\ndef test_add():\n    assert add(1, 2) == 3\n' > src/test_calc.py
cat > justfile <<'J'
# List recipes.
default:
    @just --list

# Run the test suite. Usage: just test
test:
    cd src && python3 -m pytest -q

# Deploy the current build to staging. Usage: just deploy-staging
deploy-staging:
    @echo "deployed $(git rev-parse --short HEAD 2>/dev/null || echo dev) to staging"
J
git add -A && git -c user.email=e@x -c user.name=eval commit -qm init
