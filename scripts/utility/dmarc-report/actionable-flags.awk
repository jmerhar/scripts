# Reports whether the flags file holds anything worth acting on.
#
# Reads the flags TSV, whose $1 is the category. Only policy, align and config describe something to go
# and change; info flags are context for reading the rest of the report, so a run that raised nothing but
# those is a clean run.
#
# Exits 0 when an actionable flag was seen and 1 otherwise, so the caller can use it as a condition. That
# inversion is deliberate: the caller turns it into the tool exit status, where nonzero means there is
# something to do.

$1 == "policy" || $1 == "align" || $1 == "config" { found = 1 }

END { exit !found }
