# Media Scripts

Tools for keeping a TV and film library in order — subtitle coverage and timing, and linking finished downloads into the library. For installation instructions, see the [main README](../../README.md#installation).

## Scripts

<!-- BEGIN INDEX -->
### [`dovi-active-area`](dovi-active-area/)

Reports the Dolby Vision L5 active area of Matroska files, and on request zeroes it by rewriting the RPU in place, so a display stops cropping or letterboxing a picture that already fills its frame. Requires the external tool 'dovi_tool', which Debian has no package for.

`bash 4.0+` · deps: `ffmpeg`, `jq`, `mediainfo`, `mkvtoolnix` (+`dovi_tool` macOS)

### [`link-series`](link-series/)

Links episodes from a download folder into a series' library folder, taking the show and season from the destination directory itself, so manually acquired releases join the library without a second copy of the file.

`bash 4.0+`

### [`normalize-release-names`](normalize-release-names/)

Brings episode filenames to one spelling — dots for separators, lower case, and the season and episode as S01E02 — so that sidecar pairing, library linking and episode parsers all match the same names. Renames subtitles alongside their video and refuses a rename whose destination is taken.

`bash 4.0+`

### [`subtitle-report`](subtitle-report/)

Reports on subtitle coverage for a media library, detecting embedded tracks and sidecar files and breaking down counts by language and source.

`bash 4.0+` · deps: `ffmpeg`

### [`subtitle-sync`](subtitle-sync/)

Resynchronizes drifting subtitles to a video's speech using a Whisper transcript as reference and alass for segment-aware alignment (handles ad-break, global-offset, and speed drift). Requires the external tools 'alass' and 'whisper-ctranslate2' on PATH.

`bash 4.3+` · deps: `ffmpeg`

### [`transcode-audio`](transcode-audio/)

Re-encodes the audio of Matroska files to a codec the playback chain can decode (AC-3 by default, for a receiver that cannot take Dolby Digital Plus), in one ffmpeg pass that copies the video, subtitles and chapters and keeps every audio track with its language and flags.

`bash 4.0+` · deps: `ffmpeg`, `jq`

<!-- END INDEX -->
