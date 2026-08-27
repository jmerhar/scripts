# Scores one candidate alignment against the speech reference, and profiles how far it moved each cue.
#
# Expects the reference path in `ref` and the pre-sync subtitle path in `orig`, with all three files as
# arguments. Prints one line of six numbers:
#
#   score cues runs max_abs_shift min_shift max_shift
#
# `score` is how many milliseconds of speech the candidate and the reference agree on, which is what
# alass maximizes: scoring two candidates says which of them matches the speech better. The rest
# describe the shift the candidate applied, in milliseconds, signed so that a positive shift means a
# cue moved later. `runs` counts the stretches of equal shift, so 1 is a single global offset and more
# than 1 means the alignment is segmented. A `cues` of -1 says the candidate cannot be compared with
# the original cue by cue, because one of them has no cues or the two disagree on how many; the caller
# has no profile then and must not read the shift as a small one.
#
# The three inputs are told apart by FILENAME rather than by NR == FNR, because a first file holding no
# cues would leave the next files records satisfying NR == FNR and being read as the reference,
# scoring a file against itself.
#
# The score merges each side into non-overlapping intervals first. Without that, two cues covering the
# same moment let one millisecond be counted twice and the number stops measuring coverage; ASS files
# carry simultaneous speakers routinely and SDH subtitles sometimes do. The profile pairs cues by
# index, which holds because an aligner shifts a subtitle rather than rewriting its cue list, and the
# -1 above is what catches the case where that is untrue.
#
# A run continues while the shift stays within RUN_TOLERANCE_MS of the shift that opened it, rather
# than being exactly equal. ASS and SSA timestamps have only centisecond resolution, so a single global
# offset written back into ASS lands as shifts a few milliseconds apart and an equality test would
# report every ASS file as segmented; measuring against the run rather than against the previous cue
# keeps a steady rescale from creeping along inside one run.
#
# SRT and WebVTT cue lines are found by their arrow and read from the fields either side of it rather
# than by position; ASS and SSA dialogue lines are read from the columns their Format line declares.
# Both decimal separators are accepted, as is a WebVTT timestamp that omits the hours.
function to_ms(t,   n, p) {
  gsub(/,/, ".", t)
  n = split(t, p, ":")
  if (n < 2) return -1
  return int(((((n == 3) ? p[1] : 0) * 60 + p[n - 1]) * 60 + p[n]) * 1000 + 0.5)
}
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function abs(v) { return (v < 0) ? -v : v }
function add(s, e) {
  if (s < 0 || e < s) return
  if (FILENAME == ref) { rs[++nr] = s; re[nr] = e }
  else if (FILENAME == orig) { os[++no] = s }
  else { cs[++nc] = s; ce[nc] = e }
}
# Collapses a cue list into non-overlapping intervals, in place. A cue starting at or before the
# current interval ends extends it instead of opening a new one, which also keeps the result ordered
# when a file lists its cues out of order.
function merge(n, s, e,   i, m) {
  m = 0
  for (i = 1; i <= n; i++) {
    if (m > 0 && s[i] <= e[m]) { if (e[i] > e[m]) e[m] = e[i]; continue }
    m++
    s[m] = s[i]
    e[m] = e[i]
  }
  return m
}
/^[ \t]*Format:/ { n = split($0, f, ","); for (i = 2; i <= n; i++) { if (trim(f[i]) == "Start") si = i; if (trim(f[i]) == "End") ei = i } }
/^[ \t]*Dialogue:/ { n = split($0, f, ","); add(to_ms(trim(f[si ? si : 2])), to_ms(trim(f[ei ? ei : 3]))); next }
/-->/ { n = split($0, f, " "); for (i = 2; i < n; i++) if (f[i] == "-->") { add(to_ms(f[i - 1]), to_ms(f[i + 1])); break } }
END {
  RUN_TOLERANCE_MS = 20
  cues = -1
  runs = -1
  max_abs = -1
  lo_shift = 0
  hi_shift = 0
  if (nc > 0 && nc == no) {
    cues = nc
    runs = 0
    max_abs = 0
    for (i = 1; i <= nc; i++) {
      shift = cs[i] - os[i]
      if (i == 1 || shift < lo_shift) lo_shift = shift
      if (i == 1 || shift > hi_shift) hi_shift = shift
      if (abs(shift) > max_abs) max_abs = abs(shift)
      if (i == 1 || abs(shift - run_shift) > RUN_TOLERANCE_MS) { runs++; run_shift = shift }
    }
  }
  nr = merge(nr, rs, re)
  nc = merge(nc, cs, ce)
  i = 1
  j = 1
  score = 0
  while (i <= nr && j <= nc) {
    lo = (rs[i] > cs[j]) ? rs[i] : cs[j]
    hi = (re[i] < ce[j]) ? re[i] : ce[j]
    if (hi > lo) score += hi - lo
    if (re[i] < ce[j]) i++
    else j++
  }
  printf "%d %d %d %d %d %d\n", score, cues, runs, max_abs, lo_shift, hi_shift
}
