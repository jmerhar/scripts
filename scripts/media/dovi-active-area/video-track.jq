# Reads mkvmerge -J and emits the video track properties a remux has to carry across, as
# "id default_duration language track_name".
#
# The track id is read rather than assumed to be 0: it usually is, but a file that says otherwise
# would have some other track extracted and remuxed as its video. The default duration matters more —
# a raw HEVC bitstream carries no container timing, so a remux that does not restate it leaves
# mkvmerge to guess the frame rate, and a wrong guess desynchronises every audio track in the file.
[.tracks[]? | select(.type == "video")] | first
| if . == null then empty
  else [(.id | tostring), ((.properties.default_duration // "") | tostring), (.properties.language // ""), (.properties.track_name // "")] | @tsv
  end
