# Totals failing message volume by country.
#
# Input is one "messages<TAB>country" row per failing source range, already attributed by the caller,
# which is where the geolocation answers live. Ranges are counted alongside the messages because the two
# say different things: one high-volume range is a single misconfigured or abusive host, where a hundred
# small ones under the same flag is a botnet.
#
# Ranges the lookup could not place arrive under whatever label the caller gave them and total up like any
# other, so volume nothing could attribute stays visible in the table instead of vanishing from it.
#
# A row with no country in it is not a range: a here-string input always ends in a newline, so the last
# line is empty and would otherwise total as a range of its own.

$2 != "" { msgs[$2] += $1; ranges[$2]++ }

END { for (c in msgs) printf "%d\t%d\t%s\n", msgs[c], ranges[c], c }
