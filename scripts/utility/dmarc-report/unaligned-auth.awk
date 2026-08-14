# Counts messages that authenticated but failed DMARC alignment, per header-from and auth domain.
#
# Input is the records TSV: $5 message count, $9 header_from, $10 DKIM pairs, $11 SPF pairs,
# $12 aligned-pass, $13 any-auth-pass. Only records that passed some authentication while failing
# alignment are of interest — those are the ones a missing or mismatched alignment setting explains.
#
# Passing auth domains are deduplicated per record, so a message passing both DKIM and SPF on the same
# domain counts once rather than twice.

$13 == 1 && $12 == 0 {
  # Distinct passing auth domains for THIS record, so a message that passes
  # both DKIM and SPF on the same domain is counted once, not twice.
  delete seen
  split($10 ";" $11, pairs, ";")
  for (i in pairs) {
    n = split(pairs[i], kv, ":")
    if (n == 2 && kv[2] == "pass") seen[kv[1]] = 1
  }
  for (dom in seen) cnt[$9 "\t" dom] += $5
}
END { for (k in cnt) printf "%s\t%d\n", k, cnt[k] }
