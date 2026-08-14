# Shifts every timestamp in an SRT file by a signed millisecond offset.
#
# Expects the offset in `off`. SRT-only: it relies on the "HH:MM:SS,mmm --> HH:MM:SS,mmm" cue format,
# which is why the cue line is matched on " --> " rather than by position. Negative results clamp to
# zero, since a cue cannot start before the video does and a negative timestamp would make the file
# unparseable to players. Every other line is passed through untouched, so numbering and text survive.
function toms(h,m,s,ms){ return ((h*60+m)*60+s)*1000+ms }
function fmt(t,   h,m,s,ms){
  if (t<0) t=0
  ms=t%1000; t=int(t/1000); s=t%60; t=int(t/60); m=t%60; h=int(t/60)
  return sprintf("%02d:%02d:%02d,%03d",h,m,s,ms)
}
/ --> /{
  split($1,a,"[:,]"); split($3,b,"[:,]")
  printf "%s --> %s\n", fmt(toms(a[1],a[2],a[3],a[4])+off), fmt(toms(b[1],b[2],b[3],b[4])+off)
  next
}
{ print }
