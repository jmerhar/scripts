# Replaces the content between the index markers with the contents of the file named in `tfile`.
#
# Everything outside the markers is copied through, which is what lets a README carry prose above and
# below a generated index section. The blank line printed before the END marker keeps one blank line
# between the section and what follows, so regenerating repeatedly does not accumulate or lose
# separation.
/<!-- BEGIN INDEX -->/ {
  print
  while ((getline line < tfile) > 0) print line
  close(tfile)
  found=1
  next
}
/<!-- END INDEX -->/ { print ""; found=0 }
!found { print }
