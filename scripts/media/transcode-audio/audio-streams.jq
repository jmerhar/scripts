# Reads ffprobe JSON and emits one line per audio stream: "codec channels", in stream order.
#
# The channel count is what decides a stream bitrate, and it is missing from some malformed files, so it
# falls back to 2 rather than emitting an empty field that would shift every column after it.
[.streams[]? | select(.codec_type == "audio")]
| .[]
| [(.codec_name // "unknown"), ((.channels // 2) | tostring)]
| @tsv
