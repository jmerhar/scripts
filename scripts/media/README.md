# Media Scripts

Tools for keeping a TV and film library in order — subtitle coverage and timing, and linking finished downloads into the library. For installation instructions, see the [main README](../../README.md#installation).

## Scripts

<!-- BEGIN INDEX -->
### [`link-series`](link-series/)

Links episodes from a download folder into a series' library folder, taking the show and season from the destination directory itself, so manually acquired releases join the library without a second copy of the file.

`bash 4.0+`

### [`subtitle-report`](subtitle-report/)

Reports on subtitle coverage for a media library, detecting embedded tracks and sidecar files and breaking down counts by language and source.

`bash 4.0+` · deps: `ffmpeg`

### [`subtitle-sync`](subtitle-sync/)

Resynchronizes drifting subtitles to a video's speech using a Whisper transcript as reference and alass for segment-aware alignment (handles ad-break, global-offset, and speed drift). Requires the external tools 'alass' and 'whisper-ctranslate2' on PATH.

`bash 4.3+` · deps: `ffmpeg`

<!-- END INDEX -->
