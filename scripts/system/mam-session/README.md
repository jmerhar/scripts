# `mam-session`

MyAnonamouse binds a session to the address and network it was created from, and announces fail once either changes — silently, in the sense that the client keeps trying and the tracker keeps refusing. The tracker's dynamic-seedbox endpoint exists to re-point such a session, and this drives it: on a dynamic connection, from a timer.

### What it needs, and what it deliberately does not

It needs a **session** created in the tracker's security settings with *allow session to set dynamic seedbox* enabled. It does **not** need — and will never ask for — your account password:

* An ordinary login session does not work. The endpoint refuses one as the wrong session type, so logging in to fetch a session id buys nothing.
* A session can be revoked in one click; an account cannot. If the file holding it leaks, the damage is bounded.
* A dynamic-seedbox session does not expire on a timer. What breaks it is your **ASN** changing, and adding the new network is a change only you can make in the tracker's settings — so the script detects that case and names the setting instead of retrying.

### Features

* **Calls Sparingly** — This is a private tracker's API. A call happens only when the address appears to have changed, or when a minimum interval has passed (an hour by default). `--force` overrides both.
* **No Address Service Needed** — The endpoint reports the address and network it sees, and that is what gets remembered. The optional address lookup exists only to avoid calling the tracker at all; set `IP_SERVICE=""` to drop it.
* **Refuses A Readable Config** — The session in the config file is enough to act as the account, so the script stops if the file is readable by anyone else rather than warning and carrying on.
* **Keeps The Cookie Out Of The Process List** — The session is passed in a cookie file, not as an argument, where any other user could read it with `ps`. Whatever the tracker rotates it to is kept in the same file.
* **Explains A Refusal** — Each reason the endpoint gives has a different fix, and only a person with the tracker's settings open can apply it. An ASN mismatch names the network to add; an unrecognised session says it may have been revoked or created without dynamic seedbox allowed.
* **`--status`** — Shows the stored address, the age of the last call and whether a session is held, without calling anything.

### Requirements

* `bash` 4.0+
* `curl`
* `jq`

### Usage

```bash
mam-session [OPTIONS]
```

**1. Configure** — Create `/etc/mam-session.conf` from the [template](mam-session.conf), private to the user that will run it:

```bash
sudo install -m 600 /dev/null /etc/mam-session.conf
sudoedit /etc/mam-session.conf     # set MAM_ID
```

**2. Run it from a timer.** Hourly is plenty; the script itself decides whether a call is warranted:

```cron
17 * * * * /usr/local/bin/mam-session --quiet
```

### Options

| Option | Description |
| --- | --- |
| `-f`, `--force` | Call the tracker even when the address looks unchanged and the interval has not passed. |
| `-s`, `--status` | Show what is stored and call nothing. |
| `-n`, `--dry-run` | Say what would happen without calling the tracker or writing state. |
| `-q`, `--quiet` | Say nothing unless something changed or failed, for cron. |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging. |
| `-h`, `--help` | Show the help message. |

### Example

```
$ mam-session
[INFO]: The session now points at 31.20.91.239 on ASN 50266 (Odido Netherlands B.V.). The tracker said: Completed.

$ mam-session
[INFO]: Nothing to do: the address is still 31.20.91.239.

$ mam-session --force
[ERROR]: The tracker will not accept this session from network ASN 50266 (Odido Netherlands B.V.). In its security settings, open the session and add this network under 'add additional ASN via IP address'.
```

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | The session is current, or was pointed at the new address. |
| `1` | The tracker refused, did not answer, or the configuration was unusable. |
