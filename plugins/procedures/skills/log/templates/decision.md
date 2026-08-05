<!-- TEMPLATE — a decision is ONE JSON line appended to the decisions.jsonl in your knowledge root (default ~/.claude/references/decisions.jsonl).
     Shape (keep every key; empty string over missing key):

{"ts":"<ISO-8601>","title":"<the takeaway as a sentence>","type":"decision","context":"<what raised the question>","what":"<what was decided, concretely>","rationale_or_lesson":"<why — the reasoning that makes it stick>","decided_by":"<person|assistant|together>","tags":["<search-words>"]}

     Rules:
     - title IS the takeaway ("weekly summary goes out Fridays 17:00, not Monday"),
       not the topic ("summaries").
     - A reversal of an old decision is a NEW line referencing the old title in
       context — never edit history.
     - decided_by matters: your person's decisions bind you; your own are
       defaults they can override. -->
