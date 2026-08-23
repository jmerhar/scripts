# Totals DMARC message counts by whether they aligned, over the whole reporting period.
#
# Reads the records TSV: $5 is the message count and $12 the aligned-pass flag. Counts rather than
# records are what matter — one record can stand for thousands of messages, so counting rows would
# weight a receiver that sends many small reports over one that sends few large ones.
#
# Emits "<passed> <failed>", both zero-filled so a period with no mail of one kind still yields two
# fields for the caller to read.

{ if ($12 == 1) p += $5; else f += $5 }

END { printf "%d %d", p + 0, f + 0 }
