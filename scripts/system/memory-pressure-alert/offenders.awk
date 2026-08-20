# Aggregate the per-process memory reported by top into a per-application total.
#
# Reads "command mem cmprs" rows and sums resident plus compressed bytes per
# command name. Both halves are needed: a browser spreads tens of gigabytes over
# dozens of helpers, each of which reports a small resident size while holding
# most of its footprint compressed, so resident alone points at the wrong
# process. Grouping by name is what turns 56 renderers into one line of blame.
#
# Emits "<MB> <processes> <application>" for the heaviest applications.

function to_bytes(v,    n, unit) {
  # top abbreviates sizes as 512K, 48M, 2048M, 1G and appends + or - to mark a
  # value that changed during the sample; both must come off before the number
  # can be read.
  gsub(/[+-]$/, "", v)
  unit = substr(v, length(v), 1)
  n = v
  sub(/[KMGT]$/, "", n)
  if (unit == "K") return n * 1024
  if (unit == "M") return n * 1048576
  if (unit == "G") return n * 1073741824
  if (unit == "T") return n * 1099511627776
  return n
}

# top prints a header block before the process rows. A row is only usable when
# its last two fields are sizes, so anything else is skipped rather than parsed
# into a bogus total.
NF >= 3 && $(NF) ~ /^[0-9.]+[KMGT]?[+-]?$/ && $(NF-1) ~ /^[0-9.]+[KMGT]?[+-]?$/ {
  app = $1
  # top truncates long command names and may include a trailing count; the first
  # field is enough to group by, since helpers share the name of the parent.
  total[app] += to_bytes($(NF-1)) + to_bytes($(NF))
  procs[app] += 1
}

END {
  for (app in total) {
    printf "%d %d %s\n", total[app] / 1048576, procs[app], app
  }
}
