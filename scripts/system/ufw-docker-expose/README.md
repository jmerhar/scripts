# ufw-docker-expose

Opens and closes external access to Docker-published container ports with `ufw route` rules that
survive the container being renumbered, and that do not match traffic the host merely routes.

Docker publishes a port by DNAT-ing it to the container, so by the time ufw sees the packet in the
`FORWARD` chain it is addressed to the container, not to the host. Naming that address in the rule —
which is what the obvious approach does — means the rule stops matching as soon as the container is
recreated on a different IP. External access then breaks silently while access from the LAN keeps
working, so it presents as an ISP or router fault. Matching the destination **port** instead survives
renumbering, because the port is what the publish preserved.

The destination is still constrained to the private ranges container addresses come from, and that
part matters as much as the port. See [Why the destination is
constrained](#why-the-destination-is-constrained).

### Relationship to ufw-docker

[`ufw-docker`](https://github.com/chaifeng/ufw-docker) is a **prerequisite, not an alternative**. Its
`ufw-docker install` step is what inserts ufw's forward chain into Docker's `DOCKER-USER` chain, and
that hook is the only reason ufw has any say over forwarded Docker traffic at all. Without it Docker's
own rules accept a published port before ufw's are ever consulted — the well-known "Docker bypasses
ufw" problem — so the rules this script writes would have no effect and the port would be open
regardless. Install `ufw-docker` (or an equivalent `DOCKER-USER` hook) first; this script does not
replace it, and it also does not replace `ufw-docker`'s `install`, `check` and `status` diagnostics.
It is a single script, installed from its repository rather than from a package manager:

```bash
sudo wget -O /usr/local/bin/ufw-docker https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
sudo chmod +x /usr/local/bin/ufw-docker
sudo ufw-docker install     # writes the DOCKER-USER handoff into /etc/ufw/after.rules
```

Because `ufw-docker` is not packaged for Debian or Ubuntu, nothing in this script's package metadata can
express that dependency — so it is checked at run time instead. A run on a host whose `DOCKER-USER` does
not reach ufw says so loudly and still writes the rules, since staging them before the hook exists is
legitimate:

```
[ERROR]: DOCKER-USER does not hand off to ufw, so these rules will be INERT and the port stays
reachable regardless. Run 'ufw-docker install' first.
```

What the two do differently is only the allow rule:

| | Rule written | Survives a redeploy | Granularity |
|---|---|---|---|
| `ufw-docker allow <ctr> <port>` | `route allow proto P from any to <container-ip> port N` | No — the address is baked in | One container |
| `ufw-docker-expose <port>` | `route allow proto P to <container-range> port N` | Yes — the port is what the publish preserves | Any container publishing that port |

`ufw-docker` pins the container's address, which is exactly right while that address holds and is the
part that does not survive `docker compose up` landing the container on a different IP. The rule then
matches nothing, external access breaks silently, and access from the LAN keeps working — so it reads
as an upstream fault rather than a firewall one. A stale rule is also left naming an address Docker may
later hand to a different container, which would open that container's port instead if it happens to
publish the same number.

**So why not simply write `to any port N` and be done?** Because that is a worse bug wearing the
disguise of a fix, and it is the reason this script exists rather than a one-line note in a wiki. An
unqualified rule matches every forwarded packet with that port, including traffic the host routes for
something else, and — sitting in `DOCKER-USER`, ahead of everything a VPN appends — it accepts such a
packet outright and breaks the router silently. See [Why the destination is
constrained](#why-the-destination-is-constrained). Constraining the destination to container ranges is
that fix done properly: still independent of the container's address, still inert for traffic that is
merely passing through.

Reach for `ufw-docker allow` instead when you want one specific container exposed and its address is
fixed (a compose `ipv4_address`, say), or for a Swarm service, which `ufw-docker service allow`
handles and this script does not.

### Features

- Rules keyed on the container **port**, so a redeploy that renumbers the container does not silently
  close the port from outside.
- Destination constrained to container address ranges, so the rules cannot swallow traffic the host
  is routing for a VPN exit node or a subnet router.
- Warns when `DOCKER-USER` does not hand off to ufw, which is what would make these rules inert while
  appearing to have worked.
- Advisory publish check that names the two publishes which look correct and cannot work: one bound
  to `127.0.0.1`, and one whose host port differs from the container port.
- `--dry-run` delegates to `ufw --dry-run`, so what you see is the rule set ufw would write.

### Requirements

- `ufw`, with [`ufw-docker`](https://github.com/chaifeng/ufw-docker) installed (`ufw-docker install`)
  or an equivalent `DOCKER-USER` hook — without one these rules are inert; see [Relationship to
  ufw-docker](#relationship-to-ufw-docker)
- root (changing and reading firewall rules both need it)
- `docker` is optional — without it the advisory publish check is skipped and the rules are still
  written, which is what allows a host to manage its firewall without access to the daemon

### Usage

```bash
sudo ufw-docker-expose [options] <port>[/tcp|/udp] ...
```

### Options

| Option | Description |
|---|---|
| `-c`, `--close` | Close the given ports instead of opening them. |
| `-l`, `--list` | List the forwarded allow rules and exit. |
| `-s`, `--subnet <cidr>` | Destination range to constrain the rules to. Repeatable, and replaces the defaults. |
| `-n`, `--dry-run` | Show what ufw would do, changing nothing. |
| `-d`, `--debug` | Enable debug output. |
| `-h`, `--help` | Show help and exit. |

The protocol defaults to `tcp` when a port is given without one.

### Configuration

`CONTAINER_SUBNETS` sets the destination ranges, defaulting to the three RFC 1918 blocks — where
Docker allocates bridge networks from unless `default-address-pools` says otherwise. Narrow it when
one of those blocks carries something other than containers; see the comments in
[`ufw-docker-expose.conf`](ufw-docker-expose.conf).

### Example

```bash
sudo ufw-docker-expose 8080                  # tcp 8080
sudo ufw-docker-expose 5353/udp 5353/tcp     # both protocols
sudo ufw-docker-expose --close 8080
sudo ufw-docker-expose --subnet 172.16.0.0/12 --subnet 192.168.0.0/16 8080
sudo ufw-docker-expose --list
```

### Why the destination is constrained

An unqualified `ufw route allow proto tcp to any port N` matches **every** forwarded packet carrying
that destination port — including traffic the host is routing on behalf of something else, such as a
VPN exit node or a subnet router.

That matters because of where firewall front-ends place their forward rules. [`ufw-docker`](https://github.com/chaifeng/ufw-docker) installs
ufw's forward chain into `DOCKER-USER`, which `FORWARD` reaches before anything a VPN appends. An
`ACCEPT` there terminates the chain, so a routed packet is accepted outright and whatever the router
still had to do to it never happens — most often marking it so that the router's own NAT rule will
match. The packet then leaves with an unroutable source address and no reply can come back.

The symptom is specific and misleading: clients reach services on the host itself perfectly well,
because that is the `INPUT` path and untouched, while everything routed *through* the host dies. If
you are diagnosing that, check whether the router's masquerade rule is being reached at all —
a `MASQUERADE` sitting at zero packets while traffic is flowing means something upstream in `FORWARD`
accepted it first:

```bash
sudo iptables -t nat -L -v -n
sudo iptables -L -v -n
```

Constraining the destination to container ranges keeps these rules matching DNAT-ed container traffic
and leaves routed traffic to fall through to the rules that own it.

### Exit Codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | Invalid arguments, not running as root, an unreadable `CONFIG_FILE`, or a failing `ufw` call. |
