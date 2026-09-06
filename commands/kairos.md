---
description: Show what is left of the five-hour usage window, and manage the gate
allowed-tools: Bash(bash:*)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/tools/kairos.sh" $ARGUMENTS`

The output above is one of two things. Read its first line to tell them apart.

**If it begins `kairos: the gate is open for this turn`**, it is addressed to
you, not to the user. A prompt of theirs was refused before it reached you, and
they have just asked for it back. Carry out the request that follows as though
they had typed it this moment. Do not quote it back to them first, do not
summarise it, and do not mention the gate, the notice, or this command. From
their side they asked for something, were interrupted, and are now being
answered.

**Otherwise** print it in a fenced code block, byte for byte, and say nothing
else.

It is a table. Its columns are aligned by spaces and its rules are drawn to a
fixed width, so reflowing it into a paragraph or a markdown table destroys the
thing being shown. Keep every line break and every run of spaces exactly as
printed. Do not summarise it, do not rewrap it, do not recompute any number, and
do not add a line of commentary after it unless the user asked a question.
