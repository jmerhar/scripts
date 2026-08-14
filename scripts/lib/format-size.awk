# Formats a byte count as a human-readable size, e.g. "1.23 MB".
#
# Shared by the scripts that report recovered space. Expects the count in `s`, which may be fractional
# because callers pass averages as well as totals. The unit list stops at PB, and the index is capped at
# it, so an implausibly large input degrades to "N PB" rather than reading past the array.
BEGIN {
  split("B KB MB GB TB PB", u, " ");
  if (s == 0) { print "0 B"; exit }
  i = 1;
  while (s >= 1024 && i < 6) { s /= 1024; i++ }
  printf "%.2f %s\n", s, u[i]
}
