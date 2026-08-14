# Prints the UUID mdadm.conf records for one array.
#
# Expects the device path in `dev`, and mdadm.conf on stdin or as a file argument. An ARRAY line lists
# its keys in no fixed order, so the fields are scanned for the UUID= one rather than indexed. A file
# with no matching ARRAY line prints nothing, which the caller treats as "no checkpoint to read".
$1 == "ARRAY" && $2 == dev {
  for (i = 3; i <= NF; i++) if ($i ~ /^UUID=/) { sub(/^UUID=/, "", $i); print $i }
}
