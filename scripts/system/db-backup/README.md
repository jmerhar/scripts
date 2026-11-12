# `pg-backup`

Dumps Postgres databases from their Docker containers with `pg_dump` and keeps a daily, weekly and monthly rotation of the dumps. Designed to run unattended from a systemd timer or `cron`.

### Features

* **Several databases, one run** — Every database listed in the config is dumped; naming entries on the command line dumps only those.
* **Custom-format dumps** — `pg_dump -Fc` output is compressed and can be restored selectively with `pg_restore`.
* **Daily, weekly and monthly tiers** — The first dump of each ISO week and each month is also kept in its own tier, as a hard link, so it takes its space once.
* **Missed runs cost nothing** — A tier keeps the first dump taken in its week or month, so a run missed on a Sunday or the 1st does not leave that period without a copy.
* **Safe on failure** — A dump replaces the day's file only when `pg_dump` exited 0 and the output is a custom-format dump. A failed database keeps all its earlier dumps and prunes nothing, and the others are still backed up.
* **Private files** — Dumps are mode `0640` and their directories `0750`.
* **No leftovers** — A dump interrupted by `SIGKILL` or a power cut leaves a hidden temporary file, which the next run removes once it is a day old.

### Requirements

* `bash` 4.3+
* `docker`, with the databases running in containers that have `pg_dump`
* A user able to run `docker exec`, and to write to `BACKUP_DIR`

### Usage

```bash
pg-backup [OPTIONS] [NAME...]
```

**1. Configure** — Create `/usr/local/etc/pg-backup.conf` (a [template](pg-backup.conf) is included):

```bash
BACKUP_DIR="/srv/backup/postgres"

DATABASES=(
  "app  app-postgres  app  app"
  "wiki wiki-postgres wiki wiki"
)

KEEP_DAILY=14
KEEP_WEEKLY=4
KEEP_MONTHLY=12
```

Each entry is `NAME CONTAINER USER DATABASE`. `CONTAINER` is the container's name as `docker ps` shows it; a Compose network alias does not work, since `docker exec` does not resolve one. `pg_dump` runs inside the container and connects as `USER`; the container's local connections must not need a password.

**2. Run** — `pg-backup` dumps every entry; `pg-backup app` dumps only that one.

**3. Schedule** — For example with a systemd service and timer:

```ini
# /etc/systemd/system/pg-backup.service
[Service]
Type=oneshot
User=backup
ExecStart=/usr/local/bin/pg-backup

# /etc/systemd/system/pg-backup.timer
[Timer]
OnCalendar=*-*-* 03:17
Persistent=true

[Install]
WantedBy=timers.target
```

The dumps land in `<BACKUP_DIR>/<NAME>/`:

```
daily/app-2026-11-11.dump
weekly/app-2026-W46.dump
monthly/app-2026-11.dump
```

**Restore** a dump into its database:

```bash
docker exec -i app-postgres pg_restore -U app -d app --clean --if-exists < app-2026-11-11.dump
```

### Options

| Flag | Description |
|------|-------------|
| `NAME...` | Back up only the named entries. |
| `-d`, `--debug` | Enable debug logging. |
| `-h`, `--help` | Show the help message. |
| `--version` | Show the version and exit. |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Every database was dumped. |
| `1` | A database could not be dumped, linked or pruned (the others still were), or the command line or config is invalid. |
