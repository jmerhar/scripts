# Counts messages whose SPF or DKIM authentication hit a temperror or permerror.
#
# Reads the records TSV: $10 and $11 hold the SPF and DKIM auth_results, $5 the message count. Either
# error points at the sending domain rather than at the receiver — a temperror is usually DNS timing
# out, a permerror a record that does not parse — so both are reported together as one figure to chase.
#
# Emits the message count, zero-filled so the caller can compare it numerically.

{ if ($10 ~ /:(temperror|permerror)/ || $11 ~ /:(temperror|permerror)/) e += $5 }

END { print e + 0 }
