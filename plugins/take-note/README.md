# take-note

Shared work notes for every agent on the machine.

- `/take-note` skill: agents jot plans, handoffs, blockers and gotchas in one daily file.
- SessionStart loader (capped): prints the note path, today's open items, yesterday's uncarried open items, and the 20 newest entries (by time, each labelled with its item). It loads one file: today's, or the previous day's if today has none.

## Note format

```
# YYYY-MM-DD — work notes

### <item>
- HH:MM [agent-tag] text

### Scratch
- HH:MM [agent-tag] text
```

- One `### ` heading per work item.
- Append ` — done` to a heading to close the item.

## Where notes live

`~/agent-resources/` is the convention for global, machine-wide agent resources. Notes go in `~/agent-resources/notes/YYYY-MM-DD.md`, created on first write. Set `NOTES_DIR` to override.

## Tests

```
cd plugins/take-note && bats hooks/tests
```
