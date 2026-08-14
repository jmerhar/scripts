# Sums message counts per domain, split by whether DMARC alignment passed.
#
# Input is the records TSV: $1 domain, $5 message count, $12 aligned-pass. Output is sorted by domain
# name so the report is deterministic regardless of the hash iteration order awk chooses.

{ d[$6] += $5 }
END {
  n = split("none quarantine reject", order, " "); sep = ""
  for (i = 1; i <= n; i++) if (order[i] in d) {
    printf "%s%s=%d", sep, order[i], d[order[i]]; sep = ", "
  }
  print (sep == "" ? "(none)" : "")
}
