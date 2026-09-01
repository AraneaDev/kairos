# A pane holds a whole session: a banner, whatever other plugins printed at
# startup, an input box, and a status line. Only the exchange belongs in a
# README, so everything above the marker and everything from the frame down is
# cut. Pass the marker as -v marker=...
#
# Run under LC_ALL=C, like the renderer, and for the same reason.

function bare(s) { gsub(/\033\[[0-9;?]*[A-Za-z]/, "", s); return s }

# A line that is only a clock and a model id was drawn by another plugin over
# the top of the exchange. It is nobody's output, it names no kairos state, and
# it is indented far enough right to widen the finished image by about a third
# for nothing.
function overlay(s) { return s ~ /^[ \t]+[0-9][0-9]:[0-9][0-9] (AM|PM) claude-[a-z0-9.-]+[ \t]*$/ }

{
  if (overlay(bare($0))) next
  line[++NR2] = $0
  plain = bare($0)
  if (start == 0 && index(plain, marker) > 0) start = NR2
  # The two full-width rules drawn around the input box are the landmark,
  # because the frame draws them rather than the content.
  if (plain ~ /^─────/ && length(plain) > 150) { prev = last; last = NR2 }
}

END {
  if (start == 0) start = 1
  stop = (prev > start) ? prev - 1 : NR2

  # Expanding a tool result puts the terminal into verbose mode, whose footer
  # takes the place of the input box. That is frame too, as are the blank rows
  # a pane is padded out with.
  while (stop > start) {
    tail = bare(line[stop])
    if (tail ~ /ctrl\+o to toggle/ || tail ~ /^[ \t]*$/ || (tail ~ /^─────/ && length(tail) > 150)) stop--
    else break
  }

  for (i = start; i <= stop; i++) print line[i]
}
