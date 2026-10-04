# Photography Scripts

Utilities for managing photography workflows — intelligent backups, library cleanup, and bringing video from old cameras into a format a photo service will take. For installation instructions, see the [main README](../../README.md#installation).

## Scripts

<!-- BEGIN INDEX -->
### [`modernize-video`](modernize-video/)

Converts video from old cameras (MJPEG, Indeo, MPEG-1, H.263 in AVI, MPG, 3GP or MOV) to H.264/AAC MP4, carrying the capture date across into the fields a photo service reads so the result lands in the right place in a timeline rather than at the moment it was uploaded. Decides what each file needs from the codecs it holds: already-modern files are reported and left alone, and streams that are already fine are rewrapped without re-encoding.

`bash 4.0+` · deps: `ffmpeg`, `jq`

### [`photo-backup`](photo-backup/)

A robust script for backing up photo collections from multiple sources to a remote server using rsync.

deps: `rsync`

### [`remove-sidecars`](remove-sidecars/)

A script to find and delete "sidecar" files when a corresponding RAW photo file exists.

`bash 4.0+`

<!-- END INDEX -->

