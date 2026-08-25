# `build-ffmpeg-nonfree`

Every redistributable ffmpeg — the distribution's package and the static builds alike — is GPL, and GPL cannot ship `libfdk-aac`: the Fraunhofer AAC encoder is nonfree. Compiling it in yourself is the only way to have it, which is fine for personal use and is not redistributable.

This builds a lean ffmpeg and ffprobe — fdk-aac, x264, x265, mp3lame and opus, nothing else — inside a throwaway container, and installs them into the install prefix where they shadow the distribution's copy without replacing it.

### Features

* **No Host Build Dependencies** — Everything is compiled in a container that is thrown away afterwards. The host needs docker and nothing else.
* **A Matching Binary** — The container base defaults to the host's own Ubuntu release, so the binary's glibc matches the machine it will run on, and keeps matching after an OS upgrade rebuild.
* **Current By Default, Reproducible On Request** — Each component builds from its latest stable release tag, discovered at run time, never a branch head. Every tag can be pinned instead, and each run prints the command that reproduces it exactly.
* **Self-Adjusting Workarounds** — nasm is built from source only when the base's is too old to assemble current ffmpeg assembly, and an `x265.pc` is generated only when x265's own build does not install one. Both fall away as the base moves forward.
* **Static Codecs** — The codec libraries are built static and linked in, so only system libraries stay dynamic.
* **Verified** — The installed binary is asked for its encoder list, and the run fails if `libfdk_aac` is not among them. A build that quietly lost the one feature it exists for is worse than one that stopped.
* **Safe Install** — Binaries are staged and moved into place, so a process running the old ffmpeg keeps the file it is executing rather than reading a half-written one.

### Requirements

* `bash`
* `docker`, with the invoking user able to use it
* `git` — only to discover the latest tags; not needed when every tag is pinned
* Write access to the install directory

### Usage

```bash
build-ffmpeg-nonfree [OPTIONS]
```

The compile is CPU-heavy — x265 dominates — and is capped at 2 cores by default, so expect 20-30 minutes.

```bash
# Build the current stable everything, on a base matching this host:
build-ffmpeg-nonfree

# Reproduce a known-good build:
build-ffmpeg-nonfree --base ubuntu:24.04 --ffmpeg n7.1 --x264 stable --x265 4.1 --fdk-aac v2.0.3 --opus v1.5.2
```

Revert at any time by removing what it installed; the distribution's ffmpeg is still there:

```bash
rm /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
```

### Options

| Option | Description |
| --- | --- |
| `--base IMAGE` | Container base image (default: `ubuntu:<the host's version>`). |
| `--ffmpeg TAG` | ffmpeg git tag (default: the latest stable `n`-tag). |
| `--x264 REF` | x264 branch or tag (default: `stable`; x264 cuts no release tags). |
| `--x265 TAG` | x265 tag (default: the latest stable). |
| `--fdk-aac TAG` | fdk-aac tag (default: the latest stable `v`-tag). |
| `--opus TAG` | opus tag (default: the latest stable `v`-tag). |
| `-k`, `--keep` | Keep the build workspace afterwards, for debugging. |
| `-d`, `--debug` | Enable verbose debug logging. |
| `-h`, `--help` | Show the help message. |

### Configuration

Optional; a [template](build-ffmpeg-nonfree.conf) is included. `DEST`, `CPU_LIMIT` and `LOG_DIR` are the operational settings; the tag settings pin a reproducible build without having to pass six options.

### Logging

Every run writes `<LOG_DIR>/build-ffmpeg-nonfree-<timestamp>.log` holding the resolved versions, the command that reproduces the build, the whole compile output, and the outcome. An unwritable log directory is a warning and a fall back to `$HOME` — logging is never the reason a twenty-minute build does not start.

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | ffmpeg and ffprobe are installed and `libfdk_aac` is present. |
| `1` | The build, the install or the verification failed; nothing was installed. |
