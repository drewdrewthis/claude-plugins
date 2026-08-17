#!/usr/bin/env bats
# Skill-surface contract. No test covered this before: /create-new was folded
# into /log, then /log itself was renamed to /update-records and /create-new
# deleted entirely (owner call, 2026-08-17) — the plugin now has exactly one
# record-writing entry point. That rename MOVED a skill directory and rewrote
# cross-references across the plugin. A moved file behind a live pointer is
# silent — `claude plugin validate` checks manifest schema only and never
# opens a SKILL.md. These tests make that class loud.
#
# Run: bats hooks/tests/skill-surface.bats

setup() {
  PLUGIN="$BATS_TEST_DIRNAME/../.."
  SKILLS="$PLUGIN/skills"
}

# Every skill directory must expose the file the loader looks for.
@test "every skill directory has a SKILL.md" {
  local missing=()
  for d in "$SKILLS"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/SKILL.md" ] || missing+=("$(basename "$d")")
  done
  [ "${#missing[@]}" -eq 0 ] || {
    echo "skill dirs with no SKILL.md: ${missing[*]}"
    return 1
  }
}

# Guards the loops below from passing vacuously on an empty glob.
@test "the skills directory is non-empty" {
  local n=0
  for d in "$SKILLS"/*/; do [ -d "$d" ] && n=$((n + 1)); done
  [ "$n" -ge 2 ]
}

# `name:` is the slash-command slug; a mismatch means the skill is invoked
# under one name and lives under another.
@test "each SKILL.md declares name and description, and name matches its directory" {
  local bad=()
  for f in "$SKILLS"/*/SKILL.md; do
    [ -f "$f" ] || continue
    local dir name desc
    dir="$(basename "$(dirname "$f")")"
    name="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1 | tr -d '"'"'"' ')"
    desc="$(sed -n 's/^description:[[:space:]]*//p' "$f" | head -1)"
    [ -n "$name" ] || bad+=("$dir: no name:")
    [ -n "$desc" ] || bad+=("$dir: no description:")
    [ "$name" = "$dir" ] || bad+=("$dir: name '$name' != dir '$dir'")
  done
  [ "${#bad[@]}" -eq 0 ] || {
    printf '%s\n' "${bad[@]}"
    return 1
  }
}

# Two skills answering to one slug is ambiguous at invocation time.
@test "skill slugs are unique" {
  local dupes
  dupes="$(for f in "$SKILLS"/*/SKILL.md; do
    [ -f "$f" ] && sed -n 's/^name:[[:space:]]*//p' "$f" | head -1 | tr -d '"'"'"' '
  done | sort | uniq -d)"
  [ -z "$dupes" ] || {
    echo "duplicate skill slugs: $dupes"
    return 1
  }
}

# THE regression this file exists for. Any ${CLAUDE_PLUGIN_ROOT}/... or
# ${CLAUDE_SKILL_DIR}/... path written in a skill or agent must resolve on
# disk. This is what a cross-skill file move breaks.
@test "every plugin-root file pointer in a skill or agent resolves on disk" {
  local dead=()
  local -a sources
  mapfile -t sources < <(find "$SKILLS" "$PLUGIN/agents" -name '*.md' -type f 2>/dev/null)
  [ "${#sources[@]}" -ge 1 ]

  for f in "${sources[@]}"; do
    local skilldir
    skilldir="$(dirname "$f")"
    while read -r ref; do
      [ -n "$ref" ] || continue
      local path="$ref"
      path="${path/\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN}"
      path="${path/\$\{CLAUDE_SKILL_DIR\}/$skilldir}"
      [ -e "$path" ] || dead+=("$(basename "$skilldir")/$(basename "$f") -> $ref")
    done < <(grep -oE '\$\{(CLAUDE_PLUGIN_ROOT|CLAUDE_SKILL_DIR)\}/[A-Za-z0-9._/-]+\.(md|sh|py|json)' "$f" | sort -u)
  done

  [ "${#dead[@]}" -eq 0 ] || {
    printf 'dead pointer: %s\n' "${dead[@]}"
    return 1
  }
}

# The consolidation itself: /update-records must own every kind, and the old
# log / create-new slugs must not quietly come back.
@test "update-records declares itself the single entry point and names every artifact kind" {
  local f="$SKILLS/update-records/SKILL.md"
  [ -f "$f" ]
  for kind in mistake decision solution failure-mode procedure evolution \
    principle invariant policy standard reference skill; do
    grep -q "$kind" "$f" || {
      echo "/update-records does not mention kind: $kind"
      return 1
    }
  done
}

@test "old log and create-new slugs no longer exist" {
  [ ! -d "$SKILLS/log" ]
  [ ! -d "$SKILLS/create-new" ]
}
