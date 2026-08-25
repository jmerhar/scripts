# `smart-check`

A drive's own health verdict is close to useless on its own: it stays `PASSED` until the drive has all but given up. What predicts a failure is a handful of attributes — sectors reallocated, sectors pending reallocation, sectors that could not be read during a scan — together with each drive's own failure thresholds for everything else it measures.

This reports what is worth acting on, and is silent when there is nothing to say, so it can run from cron.

### Features

* **Findings, Not A Dump** — Named checks for the counts that mean something specific, plus a general check for *any* attribute the drive itself says has reached its failure threshold. That last one is what covers attributes this script has never heard of: a fixed list of ids goes out of date silently, whereas the thresholds ship with the drive.
* **Solid-State Wear** — Reads whichever of the three wear attributes a drive carries, or an NVMe drive's `percentage_used`, and reports the rated life left as a percentage.
* **Temperature and Cabling** — Warns above a configurable temperature, and reports interface CRC errors separately because those usually mean a cable rather than a dying disk.
* **Auto-Detection, Not The Scan's Guess** — `smartctl --scan` suggests a device type, and for a SATA disk behind a common controller that suggestion is `scsi`, which returns no model and no attributes at all. The scan is used for the device list; the type is only a fallback when auto-detection tells us nothing.
* **One Report Per Drive** — A disk reachable by two paths is examined once, matched by serial number.
* **Honest About What It Could Not Read** — A document that parses but describes no drive is counted as unreadable, not as healthy. A fleet reported as fine without having been read is the failure mode worth avoiding.
* **Exit Status For Monitoring** — `0` healthy, `1` a drive is failing, `2` warnings only.

### Requirements

* `bash`
* `smartmontools` 7.0+ — the JSON output this parses
* `jq`
* Root, or `sudo`

### Usage

```bash
smart-check [OPTIONS] [DEVICE...]
```

With no devices named, every device smartctl can find is examined.

```bash
# Everything, with the reasoning shown:
smart-check

# One disk:
smart-check /dev/sdb

# From cron: silent unless there is something to say.
smart-check --quiet
```

### Options

| Option | Description |
| --- | --- |
| `-w`, `--wear PERCENT` | Warn below this much rated life left on a solid-state drive (default `20`). |
| `-t`, `--temp CELSIUS` | Warn above this temperature (default `60`). |
| `-c`, `--crc COUNT` | Warn above this many interface CRC errors (default `0`). |
| `-q`, `--quiet` | Print only devices with something to report. |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging. |
| `-h`, `--help` | Show the help message. |

### Configuration

Optional; a [template](smart-check.conf) is included, holding the three thresholds, an explicit `DEVICES` list, and `LOG_FILE`.

### Example

```
$ smart-check
/dev/sda: Samsung SSD 870 EVO 500GB, S6PXNZ0T123456, solid state, 51C
  warning: 8 interface CRC error(s) (CRC_Error_Count) — usually the cable, not the drive
/dev/sdb: WDC WD80EFAX-68KNBN0, VGH1ABCD, 5400 rpm, 50C
  nothing to report

2 device(s) examined, 1 with warnings.
```

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Every device examined is healthy. |
| `1` | A device is failing, could not be read, or the setup was unusable. |
| `2` | The only findings were warnings. |
