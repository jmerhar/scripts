# Formats a byte count as a human-readable binary size, e.g. "6.77 TiB".
#
# Binary units rather than decimal, because the figures come from the kernel, which counts in KiB.
# Expects the count in `b`. Whole bytes print without a fraction, since "512 B" reads better than
# "512.00 B"; every larger unit keeps two decimals.
BEGIN {
  split("B KiB MiB GiB TiB PiB", u, " ")
  i = 1
  while (b >= 1024 && i < 6) { b /= 1024; i++ }
  printf (i == 1 ? "%d %s" : "%.2f %s"), b, u[i]
}
