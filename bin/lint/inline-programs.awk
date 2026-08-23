# Reports lines that open an awk or jq program and do not close it on the same line.
#
# The shape being looked for is a program written inside the script that runs it:
#
#   awk '
#     BEGIN { ... }
#   ' file
#
# Detected per line rather than by tracking quotes across the file, which is what makes it safe to run
# over prose-heavy shell: a comment or heredoc containing an apostrophe cannot desynchronise a check that
# never carries state from one line to the next.
#
# A line is reported when, after removing every complete quoted segment and any trailing comment, an
# unterminated quote remains beside an awk or jq invocation. Removing the complete segments first is what
# lets the comment be found: whatever # survives that is outside a quote.
#
# Emits one line number per offending line.

# Nothing can be invoked from a line that is only a comment, and such a line is the likeliest place for a
# lone apostrophe.
/^[[:space:]]*#/ { next }

{
  rest = $0

  # Double-quoted segments first, then single. The order decides what happens to a quote of one kind
  # sitting inside a string of the other, and double-first is the way round that survives the case this
  # repository actually writes: awk -v msg="the receiver's verdict" followed by a single-quoted program.
  # Taking single first would pair the apostrophe in that message with the opening quote of the program
  # and report a line that is perfectly well formed.
  gsub(/"[^"]*"/, "", rest)
  gsub(/'[^']*'/, "", rest)

  # Whatever remains before a # is code, so the rest of the line is a comment and cannot open a program.
  sub(/#.*/, "", rest)

  if (rest !~ /['"]/) next

  # The invocation itself is unquoted code, so it survives the removal above. The boundaries keep gawk,
  # awkward and candidates.jq from matching.
  if (rest ~ /(^|[^[:alnum:]_.-])(awk|jq)([^[:alnum:]_.-]|$)/) print FNR
}
