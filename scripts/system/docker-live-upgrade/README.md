# docker-live-upgrade

Runs a command that restarts the Docker daemon, usually a package upgrade, and repairs whatever
[live-restore](https://docs.docker.com/engine/daemon/live-restore/) did not carry across it.

With `live-restore` enabled, restarting `dockerd` leaves containers running and the new daemon
reattaches to them, so an upgrade costs seconds rather than a restart of every container at once.
Docker guarantees the reattach only across patch releases. When it fails, a container either reads as
stopped (and its restart policy may start a second instance) or keeps running with nothing managing
it. A second instance beside a still-running orphan puts two processes on one data directory, which
is how a database gets corrupted, so the repair order matters:

1. Record every running container: ID, start time, main process.
2. Run the command.
3. Wait for the daemon, then compare. A container with the same start time was restored.
4. Stop orphaned processes, identified by their cgroup naming the container rather than by PID
   alone, since a PID can be reused. SIGTERM, the container's stop timeout, then SIGKILL.
5. Start or restart the affected containers in tier order, a batch at a time, each batch waiting
   for its healthchecks before the next. A container never starts before its Compose
   dependencies are ready; see [Order](#order).

A container that the daemon itself restarted, with no orphan left behind, is reported but not
touched. A restored container tied to a restarted one is restarted after it; see [Ties](#ties).

Only a container's main process is checked for. That is enough because it is PID 1 of the
container's PID namespace, and when it exits the kernel ends every other process in the namespace; a
container run with `--pid=host` has no namespace of its own, so its other processes are not covered.

### Features

- Repairs only what was not restored; a successful live-restore restarts nothing.
- Never starts a container while its orphaned process is still alive.
- Tier order from a container label, or from the systemd slice (`cgroup_parent`) a container
  already runs in, so a host that groups containers by priority needs no new labels.
- Respects Compose `depends_on`, read from the labels Compose records on each container, and warns
  when a container's tier is earlier than its dependency's.
- Restarts a live-restored container tied to a restarted one, by `restart: true` or a shared network
  namespace.
- Hooks before and after, for instance to open and close a monitoring maintenance window; the
  after-hook receives the outcome.
- Distinct exit codes for restored, repaired, failed and command-failed.

### Requirements

- Docker with `"live-restore": true` in `/etc/docker/daemon.json` (apply it with
  `systemctl reload docker`; no restart needed). The script refuses to run without it.
- root, to signal orphaned processes.
- Linux: orphans are identified through `/proc/<pid>/cgroup`.

### Usage

```bash
sudo docker-live-upgrade [options] -- <command> [args...]
```

The command runs in the foreground with the terminal attached, so an interactive `apt upgrade`
still asks for confirmation. Neither its failure nor Ctrl-C skips the check: an upgrade that fails or
is interrupted halfway may still have restarted the daemon. A dropped ssh session ends both, so over
ssh run it inside `tmux` or `screen`. An installed copy also logs to
`<prefix>/var/log/docker-live-upgrade.log`.

### Options

| Option | Description |
|---|---|
| `-d`, `--debug` | Enable debug output. |
| `-h`, `--help` | Show help and exit. |

### Configuration

All settings are optional; see [`docker-live-upgrade.conf`](docker-live-upgrade.conf).

| Setting | Default | Meaning |
|---|---|---|
| `DAEMON_TIMEOUT` | `300` | Seconds to wait for the daemon after the command. |
| `HEALTH_TIMEOUT` | `300` | Seconds a started container has to be running and healthy. |
| `POLL_INTERVAL` | `2` | Seconds between checks. |
| `BATCH_SIZE` | `3` | Containers started together within a tier. |
| `TIER_LABEL` | `docker-live-upgrade.tier` | Label holding a container's tier. |
| `CGROUP_PARENT_TIERS` | none | Tiers by cgroup parent, as `name=<tier>` entries. |
| `DEFAULT_TIER` | `50` | Tier for a container with neither. |
| `PRE_HOOK`, `POST_HOOK` | none | Command lines run with `bash -c`. |
| `LOG_FILE` | `<prefix>/var/log/docker-live-upgrade.log` when installed | Log file, as well as the terminal. |

`PRE_HOOK` runs just before the command, and once it has run `POST_HOOK`
always runs too. `POST_HOOK` sees `DOCKER_LIVE_UPGRADE_RESULT` (`restored`, `repaired`,
`command-failed` or `failed`) and `DOCKER_LIVE_UPGRADE_SUMMARY` in its environment. A failing hook is
logged and does not stop the run.

### Order

Each round starts up to `BATCH_SIZE` containers of one tier, lowest tier first and by name within a
tier, choosing only containers whose dependencies are ready, then waits for them before the next
round. A container waiting on a dependency does not hold back the rest: ready containers in later
tiers go ahead of it.

Dependencies come from the `com.docker.compose.depends_on` label, resolved to the named service's
container in the same Compose project. A dependency is ready once it is running and, if it has a
healthcheck, healthy; one that was live-restored, or was not running before the command, does not
need waiting for. When a dependency cannot be brought back, its dependents are not started, and
containers whose dependencies form a cycle are reported rather than started.

A container sharing another's network namespace (`network_mode: service:<name>` or
`container:<name>`) depends on that container too, since it cannot start without it.

### Ties

Two kinds of dependency also tie a container to what it depends on: a `depends_on` entry with
`restart: true`, and a shared network namespace. When the container it is tied to is started,
restarted, or was restarted by the daemon, a tied container that was itself live-restored is restarted
after it. Otherwise it would keep connections to an instance that no longer exists, or a network
namespace that is gone. Ties are followed transitively, and a container the daemon restarted is waited
on until it is ready before anything tied to it restarts.

A tied container is not restarted when what it is tied to cannot be brought back, or no longer exists;
it is reported as failed while still running.

A dependency is never moved earlier for the container waiting on it, so a dependent in an earlier
tier than its dependency waits for that tier. Every run warns about such a pair, because usually the
tiers are what is wrong:

```
[WARN]: api (tier 20) depends on db (tier 80), so it waits for that tier whenever both are repaired; give it tier 80 or later.
```

### Example

```bash
sudo docker-live-upgrade -- apt upgrade
sudo docker-live-upgrade -- apt install --only-upgrade docker-ce docker-ce-cli containerd.io
```

```bash
# /usr/local/etc/docker-live-upgrade.conf
CGROUP_PARENT_TIERS=(system-critical.slice=10 system-bulk.slice=90)
POST_HOOK='curl -fsS -d "$DOCKER_LIVE_UPGRADE_SUMMARY" https://ntfy.example/docker'
```

### Exit Codes

| Code | Meaning |
|---|---|
| `0` | Every container was live-restored. |
| `1` | Invalid arguments or configuration, not root, Docker unreachable, or live-restore disabled. Nothing was run. |
| `2` | Some containers were restarted, by the daemon or by this script, and all are running again. |
| `3` | Some containers could not be brought back, or the daemon did not return. |
| `4` | The command failed, and every container is running. |
