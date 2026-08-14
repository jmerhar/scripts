# Replaces the content between the table markers with the contents of the file named in `tfile`.
#
# Everything outside the markers is copied through, which is what lets a README carry prose above and
# below a generated table. The blank line printed before the END marker keeps one blank line between the
# table and what follows, so regenerating repeatedly does not accumulate or lose separation.
/<!-- BEGIN TABLE -->/ {
  print
  while ((getline line < tfile) > 0) print line
  close(tfile)
  found=1
  next
}
/<!-- END TABLE -->/ { print ""; found=0 }
!found { print }
