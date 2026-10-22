---
type: regex
pattern: '^#[^\n]*\n[\w-]*todo[\w-]*(?:\s[^:\n]*)?:(?!=)'
flags: im
target: { source: file, path: justfile }
---
