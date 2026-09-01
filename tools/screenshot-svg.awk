# A terminal capture, with its colours, drawn as SVG.
#
# Run under LC_ALL=C on purpose. Every character this has to find is ASCII or a
# known multi-byte sequence, and byte operations cut them on their boundaries
# exactly, without depending on which awk is installed or what locale it was
# started in.

function esc(s) {
  gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
  return s
}

# Display columns, not bytes. A continuation byte is the tail of a character the
# terminal drew in one cell, so counting everything else counts cells. Done with
# a lookup rather than a bracket range, because a range over high bytes is a
# collation error in some awks and silently something else in others.
function cols(s,   k, m, c, w) {
  m = split(s, k, "")
  w = 0
  for (c = 1; c <= m; c++) if (!(k[c] in cont)) w++
  return w
}

# xterm's 256: sixteen named, a 6x6x6 cube, then a grey ramp.
function xterm(n,   r, g, b, v) {
  if (n < 16) return basic[n]
  if (n < 232) {
    n -= 16
    r = int(n / 36); g = int((n % 36) / 6); b = n % 6
    return sprintf("#%02x%02x%02x", r ? r * 40 + 55 : 0, g ? g * 40 + 55 : 0, b ? b * 40 + 55 : 0)
  }
  v = (n - 232) * 10 + 8
  return sprintf("#%02x%02x%02x", v, v, v)
}

function sgr(seq,   body, p, n, i, code) {
  body = substr(seq, 3, length(seq) - 3)
  n = split(body, p, ";")
  if (n == 0) { fg = ""; bold = 0; dim = 0; italic = 0; return }
  for (i = 1; i <= n; i++) {
    code = p[i] + 0
    if (p[i] == "") code = 0
    if (code == 0) { fg = ""; bold = 0; dim = 0; italic = 0 }
    else if (code == 1) bold = 1
    else if (code == 2) dim = 1
    else if (code == 3) italic = 1
    else if (code == 22) { bold = 0; dim = 0 }
    else if (code == 23) italic = 0
    else if (code == 39) fg = ""
    else if (code >= 30 && code <= 37) fg = basic[code - 30]
    else if (code >= 90 && code <= 97) fg = basic[code - 90 + 8]
    else if (code == 38) {
      if (p[i + 1] + 0 == 5) { fg = xterm(p[i + 2] + 0); i += 2 }
      else if (p[i + 1] + 0 == 2) { fg = sprintf("#%02x%02x%02x", p[i + 2] + 0, p[i + 3] + 0, p[i + 4] + 0); i += 4 }
    }
    # Background and everything else is deliberately dropped: the panel has one
    # background, and a capture that paints its own would fight it.
    else if (code == 48) { if (p[i + 1] + 0 == 5) i += 2; else if (p[i + 1] + 0 == 2) i += 4 }
  }
}

function paint(t,   colour, style) {
  if (t == "") return
  colour = (fg == "") ? (dim ? DIM : FG) : fg
  style = ""
  if (bold) style = style " font-weight=\"600\""
  if (italic) style = style " font-style=\"italic\""
  if (dim && fg == "") style = style
  buf = buf sprintf("<tspan fill=\"%s\"%s>%s</tspan>", colour, style, esc(t))
}

BEGIN {
  FG = "#d5d8e0"; DIM = "#8b93a3"; BG = "#12141a"
  basic[0] = "#3b4048"; basic[1] = "#e06c75"; basic[2] = "#98c379"; basic[3] = "#e5c07b"
  basic[4] = "#61afef"; basic[5] = "#c678dd"; basic[6] = "#56b6c2"; basic[7] = "#c8ccd4"
  basic[8] = "#5c6370"; basic[9] = "#e06c75"; basic[10] = "#98c379"; basic[11] = "#e5c07b"
  basic[12] = "#61afef"; basic[13] = "#c678dd"; basic[14] = "#56b6c2"; basic[15] = "#ffffff"
  fg = ""; bold = 0; dim = 0; italic = 0
  for (b = 128; b <= 191; b++) cont[sprintf("%c", b)] = 1
  maxcols = 0; n = 0
}

{
  line = $0
  # tmux pads every line out to the pane width. Rendered as-is that would make
  # the image as wide as the terminal that took it rather than as wide as the
  # thing it photographed.
  gsub(/(\033\[[0-9;?]*[A-Za-z]|[ \t])+$/, "", line)

  buf = ""
  rest = line
  while (match(rest, /\033\[[0-9;?]*[A-Za-z]/)) {
    paint(substr(rest, 1, RSTART - 1))
    seq = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    if (substr(seq, length(seq), 1) == "m") sgr(seq)
  }
  paint(rest)

  n++
  out[n] = buf
  plain = line
  gsub(/\033\[[0-9;?]*[A-Za-z]/, "", plain)
  w = cols(plain)
  if (w > maxcols) maxcols = w
}

END {
  if (maxcols < 58) maxcols = 58
  cw = 8.4; lh = 21; pad = 20
  width = int(maxcols * cw + pad * 2)
  height = int(n * lh + pad * 2)
  printf "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" font-family=\"ui-monospace, SFMono-Regular, Menlo, Consolas, DejaVu Sans Mono, monospace\" font-size=\"14\">\n", width, height, width, height
  printf "<rect width=\"%d\" height=\"%d\" rx=\"8\" fill=\"%s\"/>\n", width, height, BG
  for (i = 1; i <= n; i++) {
    if (out[i] == "") continue
    printf "<text x=\"%d\" y=\"%d\" xml:space=\"preserve\">%s</text>\n", pad, pad + (i - 1) * lh + 14, out[i]
  }
  print "</svg>"
}
