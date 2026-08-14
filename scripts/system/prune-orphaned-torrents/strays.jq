# Prints the orphaned paths that belong to no torrent at all, as a JSON array.
#
# Input is the Deluge torrents-status map. An orphan owned by a torrent this filter sees is not a stray
# even when that torrent was not selected for removal: the file is still part of a live torrent, so
# deleting it directly would leave the torrent broken rather than tidy anything up.
#
# lint-args: --argjson orphans [] --arg dprefix /d --arg lprefix /l

def rewrite:
  if ($dprefix | length) > 0 and (. == $dprefix or startswith($dprefix + "/"))
  then $lprefix + .[($dprefix | length):] else . end;
# Set of every local path owned by any torrent.
( [ to_entries[]
    | .value as $t
    | (($t.download_location // $t.save_path // "") | rtrimstr("/")) as $base
    | select($base != "")
    | ($t.files // [])[]
    | (($base + "/" + .path) | rewrite) ]
  | map({(.): true}) | add // {} ) as $owned
| [ $orphans[] | select($owned[.] | not) ]
