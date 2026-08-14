# Prints one line per distinct DMARC policy signature, with the timestamp it first appeared at.
#
# Input is the policy TSV for one domain, oldest first:
#   domain  begin  p  sp  pct  adkim  aspf  np  org
#
# Absent subdomain and non-existent-domain policies inherit per RFC 7489 (sp defaults to p, np to sp),
# so they are resolved before comparing. Without that, a reporter that simply omits sp or np reads as a
# policy change whenever data from a different reporter arrives.

{
  p = $3; sp = ($4 == "-" ? p : $4); np = ($8 == "-" ? sp : $8)
  sig = "p=" p " sp=" sp " np=" np " pct=" $5 " adkim=" $6 " aspf=" $7
  if (sig != prev) { print $2 "\t" sig; prev = sig }
}
