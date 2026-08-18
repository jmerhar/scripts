# Utility Scripts

General-purpose user-facing utilities. For installation instructions, see the [main README](../../README.md#installation).

## Scripts

<!-- BEGIN INDEX -->
### [`compare-dirs`](compare-dirs/)

Recursively compares two directories and reports differences in existence, size, timestamps, and checksums.

`bash 4.0+`

### [`dmarc-report`](dmarc-report/)

Aggregates a folder of DMARC RUA reports (.xml.gz/.zip) into one overall report, tracking policy changes over time and flagging unenforced domains, unaligned senders, DNS/DKIM errors, and spoofing (grouped into subnets with per-range country lookup).

`bash 4.0+` · deps: `curl`, `jq` (+`libxml2` macOS, `libxml2-utils`, `unzip` Linux)

### [`subtitle-report`](subtitle-report/)

Reports on subtitle coverage for a media library, detecting embedded tracks and sidecar files and breaking down counts by language and source.

`bash 4.0+` · deps: `ffmpeg`

### [`subtitle-sync`](subtitle-sync/)

Resynchronizes drifting subtitles to a video's speech using a Whisper transcript as reference and alass for segment-aware alignment (handles ad-break, global-offset, and speed drift). Requires the external tools 'alass' and 'whisper-ctranslate2' on PATH.

`bash 4.3+` · deps: `ffmpeg`

### [`unlock-pdf`](unlock-pdf/)

Decrypts a password-protected PDF file using the 'qpdf' command-line tool.

deps: `qpdf`

<!-- END INDEX -->

