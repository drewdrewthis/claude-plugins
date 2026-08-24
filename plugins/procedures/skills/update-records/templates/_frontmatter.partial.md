<!-- FRONTMATTER SCHEMA PARTIAL — not a kind template: excluded from
     `/update-records <kind>` selection (no `.template.md` suffix, see
     SKILL.md's `templates/<kind>.template.md` convention) and from
     lint-frontmatter.sh's record scan (path is under templates/).

     Canonical copy of the seven required frontmatter keys. Authoritative
     source: specs/RECORD_FRONTMATTER.md — edit there first, mirror here,
     then copy into every *.template.md that carries this block. There is
     no template engine in this repo (no envsubst/mustache/jinja/include),
     so each kind template still holds its own copy for an agent to
     hand-copy into a new record — this file is the single place that
     copy must match, not a substitute for it.

     scripts/lib/frontmatter-schema.sh parses the key names below to drive
     lint-frontmatter.sh's REQUIRED_KEYS instead of a hardcoded array. Add
     or rename a key here and the linter picks it up on its next run. -->
---
id: <prefix>.<slug>                                              # required — corpus-unique join key, kind-prefixed (fm./dec./sol./proc./res./plan./prin. — see spec)
kind: <derived from containing store dir — do not hand-type>     # required — decisions/ -> decision
date: <YYYY-MM-DD>                                                # required — authoring date
keywords: [<named entities — projects, tools, commands, repos>]  # required — never empty
links: { <store>: [<id>], ... }                                   # required — edges to other records by store; {} if none
status: <active | ...>                                            # required — per-kind lifecycle value, see spec
description: <one line, ~120 chars, neutral third-person: what this record SAYS>   # required — retrieval match surface, see spec
---
