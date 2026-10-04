# Reads ffprobe JSON for one file and prints the facts a conversion decision needs, as one TSV line:
# container, duration, embedded date, video codec, audio codec, audio channel count.
#
# One line rather than one field per line, so a caller reads the lot with a single IFS split. Every field
# has a fallback, because each of them is absent from some file in a real camera archive, and a field that
# simply vanished would shift every column after it.
#
# The container is taken from major_brand rather than from format_name. ffprobe reports one shared demuxer
# name, "mov,mp4,m4a,3gp,3g2,mj2", for the whole ISO family, so format_name cannot tell an MP4 from a 3GPP
# file -- and that is the distinction deciding whether a stream copy is a finished job or still needs a
# rewrap. A brand is also what the file says about itself rather than what its name claims, so a 3GPP file
# carrying an .mp4 extension is read for what it is.
#
# A brand of "qt" is reported separately from "mp4" for the same reason: QuickTime is close enough to play
# in many places but is not the format being targeted, so a copy out of it still has to be rewrapped.

# Tab is IFS whitespace, so bash collapses a run of tabs into one delimiter and an empty field would
# shift every field after it -- turning a file with no recorded date into one whose codec is read as its
# date. No field may therefore ever come out empty, and each names what it lacks instead.
def orelse($fallback): if (. == null or . == "") then $fallback else . end;

def brand: (.format.tags.major_brand | orelse("")) | ascii_downcase | gsub(" +$"; "");

def container:
  brand as $b
  | if $b == "" then "other"
    elif ($b | startswith("3gp")) or ($b | startswith("3g2")) then "3gpp"
    elif ($b | startswith("qt")) then "quicktime"
    else "mp4"
    end;

def first_stream($type): [.streams[]? | select(.codec_type == $type)] | .[0];

[ container,
  (.format.duration | orelse("0")),
  (.format.tags.creation_time | orelse("none")),
  ((first_stream("video") | .codec_name) | orelse("none")),
  ((first_stream("audio") | .codec_name) | orelse("none")),
  ((first_stream("audio") | .channels | orelse(0)) | tostring)
] | @tsv
