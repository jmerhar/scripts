# Compute used memory, as a percentage of the total and in whole MB, from a single vm_stat sample.
#
# Counted the way Activity Monitor and Stats count it: anonymous, wired and
# compressed pages, minus the file cache and purgeable pages. Those two are
# excluded because the kernel reclaims them on demand, so they are memory being
# borrowed rather than memory being short. Subtracting them is what makes the
# figure move at all — a plain total-minus-free reads about 99% on any healthy
# Mac, because macOS lends almost every spare page to the cache.
#
# The page size is read from vm_stat rather than assumed: it differs between
# Intel and Apple silicon.
#
# Requires -v total=<bytes of installed RAM>. Emits "<percentage> <MB>", or "0 0"
# when the sample carries no page size and so cannot be interpreted.
#
# Both figures are derived from the same clamped byte count, so a report cannot
# show a percentage and a size that disagree about how much is in use.

/page size of/           { ps = $8 }
/^Pages active:/         { act = $3 }
/^Pages inactive:/       { inact = $3 }
/^Pages speculative:/    { spec = $3 }
/^Pages wired down:/     { wired = $4 }
/^Pages purgeable:/      { purge = $3 }
/^File-backed pages:/    { file = $3 }
/occupied by compressor/ { comp = $5 }

END {
  if (ps == 0 || total == 0) { print 0, 0; exit }

  used = act + inact + spec + wired + comp - purge - file
  # A sample that somehow accounts for more cache than anonymous memory would
  # otherwise report a negative shortage, which reads as healthy by accident.
  if (used < 0) used = 0

  bytes = used * ps
  # The figures come from one sample, but the kernel keeps moving pages while it
  # is taken, so the arithmetic can land a hair above the installed total.
  if (bytes > total) bytes = total

  printf "%d %d\n", 100 * bytes / total, bytes / 1048576
}
