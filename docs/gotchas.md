# docs/gotchas.md

Mechanism-level findings this repo's design is built on -- transcripts, not assertions. Every one
was checked directly on a real host (Arch, systemd 261, docker 29.7.1, `iptables` v1.8.13
(nf_tables)) or read directly out of the shipped binaries. See the main [README](../README.md) for
the design these findings justify.

Where a finding could only be established by reading a binary's string table rather than by running
it, this file says so. That distinction is load-bearing: it is the difference between "the daemon
accepts this key" and "this key does what the docs say", and only the first is claimed.

## Docker ships no systemd generator, and that is the whole reason this repo is shaped differently from `nixpods`

The podman package contains `lib/systemd/system-generators/podman-system-generator` and
`lib/systemd/user-generators/podman-user-generator`, both symlinks to its `quadlet` binary -- a
pure, offline INI-to-unit translator. `nixpods` exists because that binary can be run inside the
Nix build sandbox, at build time, so a malformed input fails the build rather than silently
producing no unit at boot.

The docker package contains nothing equivalent: no generator directory, no quadlet, no offline
translator of any kind. A docker container under systemd is a unit whose `ExecStart=` is a
foreground `docker run` **client**; the container itself is a child of `dockerd`/`containerd`.

So nixdocker writes the unit itself, and its build-time guarantee is correspondingly smaller: the
argv is checked for *shape* by the Nix type system and by this repo's own assertions, and nothing
anywhere checks that the docker CLI would accept it, because answering that needs a running daemon.
The README's "What this repo cannot promise" says the same thing in the place a reader meets first.

## `ExecStart=` is not a shell, and a quoted absolute path -- even behind a `-` prefix -- is fine

The single most load-bearing mechanical question in this repo: units here render
`ExecStart="/usr/bin/docker" "run" "--name=web" ...`, with **every** argument JSON-quoted including
the executable, and `ExecStartPre=-"/usr/bin/docker" "rm" "--force" "web"`, where a `-` prefix (ignore
a non-zero exit) sits directly in front of a quoted path. Both were checked against real systemd
rather than assumed:

```
$ systemd-analyze verify ./nixdocker-verify.service
$ echo $?
0
```

...and the same check is not vacuous -- it really does resolve that executable:

```
$ sed 's|"/usr/bin/docker"|"/usr/bin/does-not-exist-docker"|g' nixdocker-verify.service > badpath.service
$ systemd-analyze verify ./badpath.service
badpath.service: Command /usr/bin/does-not-exist-docker is not executable: No such file or directory
$ echo $?
1
```

That is what makes it safe to escape the whole argv uniformly (lib/render.nix's vendored
`escapeSystemdExecArg`, from nixpkgs' `nixos/lib/utils.nix`) instead of hand-splitting the binary
from its arguments. It matters for real values: `--health-cmd=curl -f http://localhost/health`
contains spaces and would otherwise become four separate arguments, and any `%` in a value would be
read by systemd as a specifier.

## systemd's `Restart=` is not docker's, and it does not tell you when you get that wrong

`unless-stopped` is a real `docker run --restart` policy name -- the literal string is in the docker
CLI binary -- and not a systemd one. systemd does not refuse it. It *ignores* it:

```
$ systemd-analyze verify ./unless-stopped.service
.../unless-stopped.service:5: Failed to parse Restart=unless-stopped, ignoring: Invalid argument
$ echo $?
0
```

The unit loads, with `Restart=no`. A service asking to be kept alive quietly never is. This is
strictly more dangerous on the docker side than on the podman side, because `unless-stopped` is the
spelling a docker user already has in their fingers. `nixdocker.containers.<name>.restart.policy` is
therefore a `lib.types.enum` of systemd's seven values, which is the only place that check can
happen.

`Type=oneshot` narrows the same list, and here systemd refuses outright rather than ignoring:

```
$ systemd-analyze verify ./oneshot-always.service
oneshot-always.service: Service has Restart= set to either always or on-success, which isn't allowed for Type=oneshot services. Refusing.
Unit oneshot-always.service has a bad unit file setting.
$ echo $?
1
```

"Refusing" means the unit does not load at all -- discovered on the host, at start time, with a
build that succeeded. `modules/containers.nix` asserts against the accepted list instead.

## Two supervisors: `docker run --restart` and systemd `Restart=` do not coordinate

`--restart` hands the container's lifecycle to the **daemon**, which will restart it on its own
schedule. systemd owns the unit and will restart the `docker run` **client** on its own. Neither
knows about the other; the visible symptom is a container that comes back while its unit reads
`inactive`, or two of it.

The daemon half-catches one shape of this. From the `dockerd` binary's own string table:

```
can't create 'AutoRemove' container with restart policy
```

...which only fires while `--rm` is also present -- true by default here
(`nixdocker.containers.<name>.autoRemove`), but a default is not a guarantee, and that diagnostic
arrives at container-start time on the host. `modules/containers.nix` refuses a `--restart` in
`extraArgs` at evaluation time instead.

## Docker 29 has a native nftables firewall backend -- vocabulary confirmed from the binary, behaviour not

This is the finding that decides whether docker can live on a host that is removing iptables. Read
out of the shipped `dockerd` (docker 29.7.1) string table:

| String found in `dockerd` | What it establishes |
|---|---|
| `firewall-backend` next to `json:"firewall-backend,omitempty"` on a `FirewallBackend` field | it is a real `daemon.json` key, not a CLI-only flag |
| `invalid firewall-backend` | the daemon validates the value and rejects an unrecognised one |
| `firewall-backend is set to nftables: %v` | `nftables` is a recognised value |
| `nftables: created chain`, `nftables: appended rule`, `nftables table`, `sending nft commands: ` | there is a real nftables implementation behind it, driving the `nft` tool |
| `Failed to find nft tool` | ...which is an external binary the daemon expects to find |
| `nftables is incompatible with swarm mode` | and a documented restriction that comes with it |

What is NOT established: that either backend behaves as advertised on any specific host. Nothing in
this repo has started a docker daemon. `nixdocker.daemon.firewallBackend` is therefore an option
with a `null` default (say nothing, leave docker's own default, which is `iptables`) and an
option description that says exactly this much and no more.

The starting point this matters for is the common one on a current Arch-family host: `iptables` is
1.8.x with the **nf_tables** backend -- the compatibility shim, not legacy -- so a host may already
carry a native firewall table of its own, plus libvirt's `ip/ip6 libvirt_network` if libvirt is
installed, alongside the `ip filter/mangle/nat` and `ip6 filter/mangle` tables the shim itself
presents. Note that the shim synthesizes those builtin chains even when no rule exists, which is
why "does an iptables chain exist" is not a reliable test for whether a host is legacy-backed.
Docker left at the default would add its own
chains through that shim; `firewallBackend = "nftables"` is the option that would instead put them
in a native table. Which of the two a host wants is a decision about that host, not a default this
repo may pick.

## Published ports bypass a host's INPUT rules, by design

Docker's port publishing works by DNAT plus a FORWARD accept, not by anything in the INPUT chain --
so a host firewall that filters INPUT does not filter a published container port. `-p 8080:80`
listens on every interface; `-p 127.0.0.1:8080:80` does not. That is the difference between a port
reachable from the LAN and one reachable from the host only, and it is the reason
`nixdocker.containers.<name>.ports`' own option description says so rather than leaving it to be
rediscovered.

## Docker's healthcheck never reaches systemd

`--health-cmd` and its four companions (`--health-interval`, `--health-timeout`,
`--health-retries`, `--health-start-period` -- all five verified present in the docker 29.7.1 CLI
binary) set the container's health status, which `docker ps` and `docker inspect` report. Nothing
propagates that to systemd: docker has no sd_notify path at all, so a unit whose container is
unhealthy stays `active (running)`.

Podman does have one (`--sdnotify=healthy`), which is a real capability difference between the two
engines, not a gap in this module. `nixdocker.containers.<name>.health` is therefore documented as
an observability signal rather than as supervision.

## `docker network` has no reconcile verb

There is `docker network create`, which fails when the name is taken, and `docker network inspect`,
which answers whether it is. There is nothing that takes a desired state and moves an existing
network to it.

So `nixdocker.networks.<name>` renders a create-**if-absent** oneshot, and a network that already
exists is left exactly as it is -- changing a `subnet` in Nix does not move a live network. The
generated unit prints that in its own output rather than exiting silently, and the created network
carries `--label nixdocker.managed=true` so a host can at least tell which ones came from here.

Compare named volumes, where the asymmetry is docker's rather than this repo's: `docker run
--volume=somename:/data` creates `somename` on first use, while `docker run --network=somenet`
fails with "network somenet not found". That is why there is a `nixdocker.networks` module and
deliberately no `nixdocker.volumes` one.

## system-manager rewrites `multi-user.target` when it emits a `.wants` symlink

Read out of `numtide/system-manager`'s own `nix/modules/systemd.nix`:

```nix
substituteTarget = target:
  if target == "multi-user.target" || target == "timers.target"
  then "system-manager.target"
  else target;
```

So `wantedBy = [ "multi-user.target" ]` -- the default for a container here -- is the correct
spelling on both planes, and on the system-manager plane the symlink lands in
`system-manager.target.wants/` rather than `multi-user.target.wants/`. A host looking for the
enable symlink in the obvious place will not find it. `checks/system-manager-eval-tests.nix` asserts
against the substituted path for exactly this reason.

## system-manager cannot drop into a distro's unit, only replace it -- which is why the daemon is pulled in by a target

The same etc builder decides what happens to a Nix-side `systemd.services.<name>` definition:

```sh
for i in <every enabled unit>; do
  fn=$(basename $i/*)
  if [ -e $out/$fn ]; then          # a systemd.packages entry already provided this file
    mkdir -p $out/$fn.d
    ln -s $i/$fn $out/$fn.d/overrides.conf
  else
    ln -fs $i/$fn $out/            # ...otherwise it is installed as the unit itself
  fi
done
```

The drop-in branch only fires when some package in `systemd.packages` already provided a file of
that name. A distro's `/usr/lib/systemd/system/docker.service` is not in that tree, so defining
`systemd.services.docker` here would take the `else` branch and land a **replacement**
`/etc/systemd/system/docker.service`, shadowing the distro's own.

nixdocker therefore never names `docker.service` as a unit it defines. `nixdocker.daemon.enable`
installs `nixdocker-daemon.target`, a unit this config does own, carrying `Requires=docker.service`
-- an ordinary dependency, resolved by systemd through its normal unit search path, where the
distro's file already is. `checks/system-manager-eval-tests.nix` asserts both halves: the target
exists and requires it, and no `docker.service` appears in the tree this config installs.
