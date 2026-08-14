# Selects the torrents whose media files are orphaned, as JSON objects sorted oldest first.
#
# Input is the Deluge torrents-status map, keyed by hash. The caller supplies the orphan set, the
# filename patterns to ignore, the significance ratio, and the two path prefixes that translate a
# Deluge-reported path into a local one.
#
# lint-args: --argjson orphans [] --argjson excludes [] --argjson minratio 0.1 --arg dprefix /d --arg lprefix /l

# Rewrite a Deluge-reported absolute path into the local filesystem path.
def rewrite:
  if ($dprefix | length) > 0 and (. == $dprefix or startswith($dprefix + "/"))
  then $lprefix + .[($dprefix | length):] else . end;
($orphans | map({(.): true}) | add // {}) as $set
| def glob_to_regex($g):
    "^" + ($g
      | gsub("(?<c>[.+^$()\\[\\]{}|\\\\])"; "\\\(.c)")
      | gsub("\\*"; ".*")
      | gsub("\\?"; ".")) + "$";
($excludes | map(glob_to_regex(.))) as $exre
| def is_media($p):
    ($p | split("/") | last) as $b
    | (any($exre[]; . as $re | ($b | test($re; "i"))) | not);
[ to_entries[]
  | .key as $hash
  | .value as $t
  # Skip torrents with no save location (e.g. metadata-only/error state).
  # The `// ""` is what keeps rtrimstr off a null; dropping the torrent
  # outright is what stops its files being resolved against an empty base,
  # which would compare scanned orphans against bare "/name" paths.
  | (($t.download_location // $t.save_path // "") | rtrimstr("/")) as $base
  | select($base != "")
  | (($t.files // []) | map(. + {abs: (($base + "/" + .path) | rewrite)})) as $files
  | ($files | map(select(is_media(.abs)))) as $media
  | (($media | map(.size) | max) // 0) as $maxsize
  | ($media | map(select($set[.abs]))) as $orphaned
  | ($media | map(select($set[.abs] | not))) as $linked
  # Candidate only if at least one orphaned media file is "significant" —
  # at least $minratio of the torrent largest media file. This ignores
  # extras/spam (deleted scenes, release-group advert clips) that are tiny
  # next to the real feature and would otherwise flag a still-wanted torrent.
  | select(any($orphaned[]; .size >= ($maxsize * $minratio)))
  | { hash: $hash,
      name: $t.name,
      total_size: ($t.total_size // 0 | floor),
      freed: ($orphaned | map(.size) | add // 0 | floor),
      time_added: ($t.time_added // 0 | floor),
      n_orphan: ($orphaned | length),
      n_media: ($media | length),
      orphaned: [ $orphaned[] | {path: .abs, size: (.size // 0 | floor)} ],
      linked:   [ $linked[]   | {path: .abs, size: (.size // 0 | floor)} ] } ]
| sort_by(.time_added)
| .[]
