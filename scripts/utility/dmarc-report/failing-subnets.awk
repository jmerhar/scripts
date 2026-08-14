# Groups failing source addresses into subnets, with the busiest address in each as its representative.
#
# Input is the records TSV: $4 source IP, $5 message count, $12 aligned-pass. IPv4 groups to /24 and
# IPv6 to /64, the smallest block a single sender is normally allocated.
#
# The representative is a real address seen in the data rather than the network address, so a
# geolocation lookup returns where the mail came from instead of failing on an address nothing is
# assigned to.

function subnet(ip,   a) {
  if (index(ip, ":")) { split(ip, a, ":"); return a[1] ":" a[2] ":" a[3] ":" a[4] "::/64" }
  split(ip, a, "."); return a[1] "." a[2] "." a[3] ".0/24"
}
$12 == 0 && $4 != "" {
  s = subnet($4); msgs[s] += $5
  if ($5 >= repmax[s]) { repmax[s] = $5; rep[s] = $4 }
}
END { for (s in msgs) printf "%d\t%s\t%s\n", msgs[s], s, rep[s] }
