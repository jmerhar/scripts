# Utility Scripts

General-purpose user-facing utilities. For installation instructions, see the [main README](../../README.md#installation).

## Scripts

<!-- BEGIN INDEX -->
### [`compare-dirs`](compare-dirs/)

Recursively compares two directories and reports differences in existence, size, timestamps, and checksums.

`bash 4.0+`

### [`dmarc-report`](dmarc-report/)

Aggregates a folder of DMARC RUA reports (.xml.gz/.zip) into one overall report, tracking policy changes over time and flagging unenforced domains, unaligned senders, DNS/DKIM errors, and spoofing (grouped into subnets with per-range country lookup, or totalled by country).

`bash 4.0+` · deps: `curl`, `jq` (+`libxml2` macOS, `libxml2-utils`, `unzip` Linux)

### [`unlock-pdf`](unlock-pdf/)

Decrypts a password-protected PDF file using the 'qpdf' command-line tool.

deps: `qpdf`

<!-- END INDEX -->

