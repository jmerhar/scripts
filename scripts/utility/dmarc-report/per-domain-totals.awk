# Totals messages per domain: total, aligned-pass, fail, and fail percentage.
#
# Input is the records TSV: $1 domain, $5 message count, $12 aligned-pass. The `+ 0` on each sum prints
# a zero rather than an empty field for a domain that only ever passed or only ever failed, since an
# unset awk array element is the empty string.

{ m[$1] += $5; if ($12 == 1) p[$1] += $5; else f[$1] += $5 }
END { for (d in m) printf "%s\t%d\t%d\t%d\t%d\n", d, m[d], p[d] + 0, f[d] + 0,
        (m[d] > 0 ? f[d] * 100 / m[d] : 0) }
