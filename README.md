# Shell Scripts Collection

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A collection of packaged shell scripts for macOS and Linux, distributed via [Homebrew](https://brew.sh/) and [APT](https://jmerhar.github.io/apt-scripts/).

## Available Scripts

<!-- BEGIN INDEX -->
### [`build-ffmpeg-nonfree`](scripts/system/build-ffmpeg-nonfree/)

Builds a lean ffmpeg and ffprobe with the nonfree libfdk-aac encoder in a throwaway container matching the host's release, from each component's latest stable tag or from pinned ones, and installs them where they shadow the distribution's copy.

deps: `git` _(Linux only)_

### [`compare-dirs`](scripts/utility/compare-dirs/)

Recursively compares two directories and reports differences in existence, size, timestamps, and checksums.

`bash 4.0+`

### [`dmarc-report`](scripts/utility/dmarc-report/)

Aggregates a folder of DMARC RUA reports (.xml.gz/.zip) into one overall report, tracking policy changes over time and flagging unenforced domains, unaligned senders, DNS/DKIM errors, and spoofing (grouped into subnets with per-range country lookup, or totalled by country).

`bash 4.0+` · deps: `curl`, `jq` (+`libxml2` macOS, `libxml2-utils`, `unzip` Linux)

### [`dovi-active-area`](scripts/media/dovi-active-area/)

Reports the Dolby Vision L5 active area of Matroska files, and on request zeroes it by rewriting the RPU in place, so a display stops cropping or letterboxing a picture that already fills its frame. Requires the external tool 'dovi_tool', which Debian has no package for.

`bash 4.0+` · deps: `ffmpeg`, `jq`, `mediainfo`, `mkvtoolnix` (+`dovi_tool` macOS)

### [`link-series`](scripts/media/link-series/)

Links episodes from a download folder into a series' library folder, taking the show and season from the destination directory itself, so manually acquired releases join the library without a second copy of the file.

`bash 4.0+`

### [`local-backup`](scripts/system/local-backup/)

A generic script to create and automatically prune rsync-based system backups.

`bash 4.0+` · deps: `rsync`

### [`mam-session`](scripts/system/mam-session/)

Points a MyAnonamouse dynamic-seedbox session at the machine's current address when it changes, calling the tracker sparingly, keeping the session out of the process list, and turning each refusal into the tracker setting that has to change.

`bash 4.0+` · deps: `curl`, `jq`

### [`mdcheck-progress`](scripts/system/mdcheck-progress/)

Reports the progress of an MD RAID check (Debian's monthly mdcheck scrub), including while it is paused between nightly windows, with a schedule-aware estimate of when it will finish.

`bash 4.0+` · deps: `mdadm` _(Linux only)_

### [`memory-pressure-alert`](scripts/system/memory-pressure-alert/)

Warns while a Mac is filling up — swap growing and memory use climbing — rather than once it has already stalled, and names the heaviest applications by resident plus compressed memory.

_(macOS only)_

### [`modernize-video`](scripts/photography/modernize-video/)

Converts video from old cameras (MJPEG, Indeo, MPEG-1, H.263 in AVI, MPG, 3GP or MOV) to H.264/AAC MP4, carrying the capture date across into the fields a photo service reads so the result lands in the right place in a timeline rather than at the moment it was uploaded. Decides what each file needs from the codecs it holds: already-modern files are reported and left alone, and streams that are already fine are rewrapped without re-encoding.

`bash 4.0+` · deps: `ffmpeg`, `jq`

### [`nopasswd-sudo`](scripts/system/nopasswd-sudo/)

Toggles temporary passwordless sudo for a user, with an in-session auto-revoke timer and a boot-time safety net so it never stays enabled by accident.

deps: `sudo` _(Linux only)_

### [`normalize-release-names`](scripts/media/normalize-release-names/)

Brings episode filenames to one spelling — dots for separators, lower case, and the season and episode as S01E02 — so that sidecar pairing, library linking and episode parsers all match the same names. Renames subtitles alongside their video and refuses a rename whose destination is taken.

`bash 4.0+`

### [`photo-backup`](scripts/photography/photo-backup/)

A robust script for backing up photo collections from multiple sources to a remote server using rsync.

deps: `rsync`

### [`prune-orphaned-torrents`](scripts/system/prune-orphaned-torrents/)

Finds orphaned media files left by *arr hard-linking and interactively removes the corresponding torrents from Deluge.

`bash 4.0+` · deps: `curl`, `jq`

### [`remove-old-kernels`](scripts/system/remove-old-kernels/)

Purges the kernel packages a Debian or Ubuntu system no longer needs, keeping the running kernel even when it is not the newest installed, and naming every package it removes rather than letting apt decide what else is unneeded.

deps: `sudo` _(Linux only)_

### [`remove-sidecars`](scripts/photography/remove-sidecars/)

A script to find and delete "sidecar" files when a corresponding RAW photo file exists.

`bash 4.0+`

### [`smart-check`](scripts/system/smart-check/)

Reports the SMART findings that actually predict a disk failing — reallocated and pending sectors, any attribute past the drive's own failure threshold, solid-state wear, temperature and interface errors — with an exit status a cron job or monitor can act on.

deps: `smartmontools`, `jq` _(Linux only)_

### [`subtitle-report`](scripts/media/subtitle-report/)

Reports on subtitle coverage for a media library, detecting embedded tracks and sidecar files and breaking down counts by language and source.

`bash 4.0+` · deps: `ffmpeg`

### [`subtitle-sync`](scripts/media/subtitle-sync/)

Resynchronizes drifting subtitles to a video's speech using a Whisper transcript as reference and alass for segment-aware alignment (handles ad-break, global-offset, and speed drift). Requires the external tools 'alass' and 'whisper-ctranslate2' on PATH.

`bash 4.3+` · deps: `ffmpeg`

### [`transcode-audio`](scripts/media/transcode-audio/)

Re-encodes the audio of Matroska files to a codec the playback chain can decode (AC-3 by default, for a receiver that cannot take Dolby Digital Plus), in one ffmpeg pass that copies the video, subtitles and chapters and keeps every audio track with its language and flags.

`bash 4.0+` · deps: `ffmpeg`, `jq`

### [`ufw-docker-expose`](scripts/system/ufw-docker-expose/)

Opens external access to Docker-published container ports using ufw route rules keyed on the port rather than the container's address, so a redeploy that renumbers the container cannot silently close the port from outside, and constrained to container address ranges so the rules do not swallow traffic the host routes for a VPN exit node or subnet router.

deps: `ufw` _(Linux only)_

### [`unlock-pdf`](scripts/utility/unlock-pdf/)

Decrypts a password-protected PDF file using the 'qpdf' command-line tool.

deps: `qpdf`

<!-- END INDEX -->

## Repository Structure

```
scripts.yaml      Central manifest — all publishable scripts and their metadata
scripts/          User-facing scripts, organized by topic
  system/           System administration tools; config files live here too
  utility/          General-purpose utilities
  media/            TV and film library maintenance
  photography/      Photography workflow automation
  lib/              Shared library (sourced at dev time, inlined at build time)
bin/              Internal CI/CD tooling (not published as packages)
test/             bats test suites, command stubs and the shared test helper
```

## Code Style

Bash scripts follow the
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
All code is checked with [ShellCheck](https://www.shellcheck.net/) in CI.

## Tests

[bats-core](https://github.com/bats-core/bats-core) suites in `test/`, run against
Linux and macOS in CI:

```bash
make install    # brew install bats-core yq
make test       # run the suite
make check      # ShellCheck + tests
make coverage   # the suite under kcov, then the coverage gate
```

Line coverage is published per commit at
[jmerhar.github.io/coverage/scripts](https://jmerhar.github.io/coverage/scripts/).

See [`test/README.md`](test/README.md) for how the suites are structured and how to
add one.

## Installation

The recommended approach is to use a package manager, which handles dependencies and updates automatically.

Most of these scripts need **bash 4.0 or newer** (one needs 4.3). Both package managers install a
suitable bash and point the script at it, so there is nothing extra to do — this matters mainly on
macOS, which still ships bash 3.2 as `/bin/bash`. A script installed from a plain tarball checks the
version itself and says so rather than failing obscurely.

### macOS (Homebrew)

```bash
brew tap jmerhar/scripts
brew install unlock-pdf        # or any script name from the index above
```

### Debian / Ubuntu (APT)

```bash
# Add the GPG key
wget -qO- https://jmerhar.github.io/apt-scripts/public.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/jmerhar-scripts.gpg

# Add the repository source
echo "deb [arch=all signed-by=/etc/apt/keyrings/jmerhar-scripts.gpg] https://jmerhar.github.io/apt-scripts/ stable main" \
  | sudo tee /etc/apt/sources.list.d/jmerhar-scripts.list

# Install
sudo apt-get update
sudo apt-get install unlock-pdf   # or any script name from the index above
```

### Direct Download

Each [GitHub Release](https://github.com/jmerhar/scripts/releases) includes a self-contained tarball with just the script (and its config template, if any). Download, extract, and run:

```bash
# Example: download the latest local-backup release
curl -fsSL https://github.com/jmerhar/scripts/releases/download/local-backup-v1.3.0/scripts-local-backup-v1.3.0.tar.gz \
  | tar xz
cd scripts-local-backup-v1.3.0
chmod +x local-backup.sh
./local-backup.sh -h
```

Scripts that ship with a config file will include it in the same directory, so they work out of the box.

## Configuration

Scripts that read a config file look for it in this order:

1. `$CONFIG_FILE`, if set
2. the script's own directory — how the tarballs above work out of the box
3. `<install-prefix>/etc/` — where Homebrew and APT put it
4. `/etc/`

`CONFIG_FILE` is useful for running one script against several configurations:

```bash
CONFIG_FILE=~/backup-photos.conf local-backup
```

Because naming a file excludes the alternatives, an unreadable `CONFIG_FILE` is an error rather than a
silent fall back to the search.

## Contributing

Contributions are welcome. Open an issue to discuss changes or submit a pull request.
Please run `make check` first, and register any new script in `scripts.yaml`.

## License

Distributed under the [MIT License](LICENSE).
