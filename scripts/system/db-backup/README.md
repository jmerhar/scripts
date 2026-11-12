# `db-backup`

Backs up Postgres, MariaDB, MongoDB and SQLite databases with a daily, weekly and monthly rotation, and verifies and restores the backups. Designed to run unattended from a systemd timer or `cron`.

### Features

* **Four engines, one run** — Postgres, MariaDB and MongoDB are dumped inside their Docker containers with the tools their images ship; SQLite files are copied on the host.
* **No credentials in the config** — MariaDB's root password is read from the container's own environment, inside the container.
* **Daily, weekly and monthly tiers** — The first dump of each ISO week and each month is also kept in its own tier, as a hard link, so it takes its space once.
* **Missed runs cost nothing** — A tier keeps the first dump taken in its week or month, so a run missed on a Sunday or the 1st does not leave that period without a copy.
* **Checked before kept** — A dump replaces the day's file only when its tool succeeded and the result is a complete dump of its format. A failed entry keeps all its earlier dumps and prunes nothing, and the others are still backed up.
* **Verify** — Restores each entry's newest dump into a throwaway container from the same image, with no network, or runs SQLite's integrity check on a copy, to prove the backups restore.
* **Restore** — Puts a dump back, after a prominent warning and a confirmation.
* **Private files** — Dumps are mode `0640` and their directories `0750`.
* **No leftovers** — A dump interrupted by `SIGKILL` or a power cut leaves a hidden temporary file, which the next run removes once it is a day old.

### Requirements

* `bash` 4.3+
* `docker`, for Postgres, MariaDB and MongoDB, with a user able to run `docker exec`
* `sqlite3` 3.27+, for SQLite
* `gzip`
* Room under `TMPDIR` (default `/tmp`) for one decompressed copy of the largest SQLite database, which backup and verify use as scratch; a restore decompresses beside the database file instead, so its rename into place is atomic

### Usage

```bash
db-backup [OPTIONS] [backup] [NAME...]
db-backup [OPTIONS] list [NAME...]
db-backup [OPTIONS] verify [NAME...]
db-backup [OPTIONS] restore NAME [DUMP]
```

**1. Configure** — Create `/usr/local/etc/db-backup.conf` (a [template](db-backup.conf) is included):

```bash
BACKUP_DIR="/srv/backup/databases"

DATABASES=(
  "postgres app   app-postgres app app"
  "mariadb  books books-mariadb books"
  "mongodb  media media-mongo media"
  "sqlite   wiki  /srv/wiki/data/wiki.db"
)

KEEP_DAILY=14
KEEP_WEEKLY=4
KEEP_MONTHLY=12
```

| Engine | Entry | Connects as |
|--------|-------|-------------|
| Postgres | `postgres NAME CONTAINER USER DATABASE` | `USER`, over the container's local socket, which must not need a password |
| MariaDB | `mariadb NAME CONTAINER DATABASE` | root, with the container's `MARIADB_ROOT_PASSWORD` (or `MYSQL_ROOT_PASSWORD`) |
| MongoDB | `mongodb NAME CONTAINER DATABASE` | no authentication |
| SQLite | `sqlite NAME PATH` | the file on this host; `PATH` is the rest of the entry, so it may contain spaces |

`CONTAINER` is the container's name as `docker ps` shows it; a Compose network alias does not work, since `docker exec` does not resolve one. For SQLite, the user running the backup needs write access to the database's directory, because a reader of a WAL database writes its `-shm` file.

**2. Back up** — `db-backup` dumps every entry; `db-backup app` dumps only that one. The dumps land in `<BACKUP_DIR>/<NAME>/`:

```
daily/app-2026-11-11.dump
weekly/app-2026-W46.dump
monthly/app-2026-11.dump
```

| Engine | Dump |
|--------|------|
| Postgres | `pg_dump -Fc`, custom format (`.dump`) |
| MariaDB | `mariadb-dump --single-transaction --routines --triggers --databases`, gzipped (`.sql.gz`) |
| MongoDB | `mongodump --archive --gzip` (`.archive.gz`) |
| SQLite | a copy taken with `VACUUM INTO` on a read-only connection, gzipped (`.sqlite.gz`) |

**3. Schedule** — For example with a systemd service and timer:

```ini
# /etc/systemd/system/db-backup.service
[Service]
Type=oneshot
User=backup
ExecStart=/usr/local/bin/db-backup

# /etc/systemd/system/db-backup.timer
[Timer]
OnCalendar=*-*-* 03:17
Persistent=true

[Install]
WantedBy=timers.target
```

**4. Verify** — `db-backup verify` restores each entry's newest daily dump into a throwaway container started from the source container's image, with no network, and checks the result holds tables; a SQLite copy gets SQLite's full integrity check instead. The container is removed afterwards.

**5. Restore** — `db-backup list app` shows the dumps. `db-backup restore app` restores the newest daily dump; `db-backup restore app 2026-W46` restores that period's dump from whichever tier holds it, and a path restores that file.

`db-backup` knows nothing about the applications that use a database, so it cannot stop them. **Stop every application that uses the database before restoring**, and start it again afterwards: one that keeps running can write to the database mid-restore, or keep serving data it cached from the old contents. The restore prints a warning saying so and asks for confirmation; `--yes` skips the question but not the warning.

| Engine | Restore |
|--------|---------|
| Postgres | `pg_restore --clean --if-exists --single-transaction`, so a failure leaves the database as it was |
| MariaDB | the dump piped into the `mariadb` client; it recreates the database |
| MongoDB | `mongorestore --drop`, limited to the entry's database |
| SQLite | the copy is checked, given the old file's owner and mode, and renamed over it; the old `-wal` and `-shm` are deleted, since a leftover write-ahead log would be replayed onto the restored file |

### Options

| Flag | Description |
|------|-------------|
| `NAME...` | Act only on the named entries. |
| `-y`, `--yes` | Restore without asking for confirmation. |
| `-C`, `--no-color` | Disable coloured output. |
| `-d`, `--debug` | Enable debug logging. |
| `-h`, `--help` | Show the help message. |
| `--version` | Show the version and exit. |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Every entry was backed up or verified, or the restore succeeded. |
| `1` | An entry could not be backed up or verified (the others still were), a restore failed or was cancelled, or the command line or config is invalid. |
