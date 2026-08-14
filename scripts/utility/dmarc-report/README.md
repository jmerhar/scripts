# `dmarc-report`

Aggregates a folder of DMARC RUA (aggregate) reports into one overall report, flagging anything worth a human's attention: domains not yet enforcing, sampling (`pct` < 100), senders that authenticated but did not align, SPF/DKIM DNS/config errors, aligned mail that was still quarantined or rejected, and the volume and top sources of outright spoofing (grouped into subnets with a best-effort country per range).

### Features

* **One combined view** — Reads every `.xml.gz` / `.zip` / `.xml` report in a directory and merges them, tracking how each domain's published policy changed over time.
* **Alignment-aware** — Distinguishes DMARC-enforced "aligned pass" from merely "authenticated", surfacing authenticated-but-unaligned senders as the interesting middle ground.
* **Spoofing breakdown** — Groups failing sources into subnets and annotates each range with a best-effort country lookup.
* **Actionable exit status** — Exits `2` when a policy, alignment, or config flag is raised (handy for monitoring); spoofing and info flags do not affect the exit status.
* **Colored output** — Auto-disables when piped.

### Requirements

* `xmllint` — `libxml2` on Homebrew, `libxml2-utils` on Debian.
* `unzip` — to read `.zip` reports.
* `curl` and `jq` — optional; best-effort country lookup for failing ranges.

### Usage

```bash
dmarc-report [OPTIONS] [DIRECTORY]
```

If no directory is given, the current directory is used.

### Options

| Flag | Description |
|------|-------------|
| `-a`, `--all` | List every failing source range, not just the top ones. |
| `-w`, `--warn-rate PCT` | Annotate the summary when the DMARC fail rate reaches PCT percent (0–100). Informational only. |
| `-C`, `--no-color` | Disable colored output. |
| `-h`, `--help` | Show usage information. |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Clean run (no actionable flags). |
| `2` | An actionable policy, alignment, or config flag was raised. |
