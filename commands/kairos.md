---
description: Show what is left of the five-hour usage window, and manage the gate
allowed-tools: Bash(bash:*)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/tools/kairos.sh" $ARGUMENTS`

Print the output above in a fenced code block, byte for byte, and say nothing
else.

It is a table. Its columns are aligned by spaces and its rules are drawn to a
fixed width, so reflowing it into a paragraph or a markdown table destroys the
thing being shown. Keep every line break and every run of spaces exactly as
printed. Do not summarise it, do not rewrap it, do not recompute any number, and
do not add a line of commentary after it unless the user asked a question.
