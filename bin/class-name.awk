# Turns a script name into the CamelCase class name a Homebrew formula requires.
#
# Input is one name on stdin, with -F'[-_]' splitting it, so "prune-orphaned-torrents" becomes
# "PruneOrphanedTorrents". Homebrew derives the expected class name from the formula filename the same
# way, so a mismatch makes the formula fail to load rather than merely look wrong.
{
  for (i=1; i<=NF; i++) {
    printf "%s", toupper(substr($i,1,1)) substr($i,2)
  }
  print ""
}
