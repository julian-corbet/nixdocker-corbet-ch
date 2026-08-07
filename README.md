# nixdocker

**Typed Nix options for digest-pinned docker containers, and a declarative `dockerd`, on a plane
that has no `virtualisation.*` -- rendered to ordinary systemd units, with the daemon off unless a
host says otherwise.**

## The problem this repo exists to fix

On NixOS, `virtualisation.docker` and `virtualisation.oci-containers` already exist and are
perfectly good. **On a foreign distro managed by [system-manager](https://github.com/numtide/system-manager),
neither exists at all** -- there is no `virtualisation.*` namespace on that plane. A workstation
running Arch or Debian with its configuration in Nix has, for docker, exactly nothing: no typed
container surface, no declarative `/etc/docker/daemon.json`, no way to say "this host wants the
docker daemon" other than remembering to run `systemctl enable docker` by hand once and hoping the
next reinstall remembers too.

That is the gap this repo fills, and it is why the system-manager backend here is the **primary**
one rather than the second opinion.

Alongside that, it carries one policy this author is not willing to re-litigate per service:

- **an image runs from a digest, or the build fails by name** (`allowFloatingTag = true` is the one
  opt-out, and it warns by container name every single build);
- **one supervisor** -- systemd's `Restart=`, never the daemon's `--restart`, and a `--restart`
  smuggled through the escape hatch is refused at evaluation time;
- **the daemon is off unless a host says otherwise**, and declaring a container counts as saying
  otherwise, out loud, in the config.

## What this repo cannot promise

Read this before the rest, because the resemblance to this repo's podman sibling
([`nixpods`](#why-this-is-not-a-nixpods-backend)) invites a stronger reading than is true.

nixpods' central claim is that podman's own quadlet **generator** -- a real systemd generator
shipped inside the podman package -- is run inside the Nix build sandbox, so a malformed container
fails the *build*, translated by the same binary that would otherwise translate it at boot.

**Docker ships no generator.** There is no docker quadlet, nothing under
`lib/systemd/system-generators/`, no offline translator of any kind. A docker container under
systemd is a unit whose `ExecStart=` is a foreground `docker run` client; the container is a child
of `dockerd`. So nixdocker composes the unit itself, and what it can prove is narrower:

| Checked here | Not checked here |
|---|---|
| the image is digest-pinned, or explicitly and loudly not | that the rendered `docker run` argv is one the docker CLI accepts -- that needs a running daemon |
| every referenced network is declared, or is a docker built-in | that a network which already exists matches what Nix asked for (`docker network` has no reconcile verb) |
| `Restart=` is a value systemd accepts, and is legal for `Type=oneshot` | that the container inside is healthy -- docker's healthcheck never reaches systemd |
| no second supervisor (`--restart`) reaches the unit | anything about the daemon's actual firewall behaviour; see `firewallBackend` below |
| the composed unit round-trips through systemd's own unit writer intact | |

Two of those deserve their own sentence because they are the ones most likely to be mistaken for
bugs later:

- **A network that already exists is left exactly as it is.** Changing a `subnet` in Nix does not
  move a live network. This is a docker limitation, it is unfinished rather than broken, and the
  generated unit says so in its own output.
- **A container's healthcheck is an observability signal, not supervision.** Docker has no
  sd_notify path (podman's `--sdnotify=healthy` does), so a unit whose container is unhealthy stays
  `active (running)`.

[`docs/gotchas.md`](docs/gotchas.md) carries the transcripts behind all of this.

## The mechanism

Each `nixdocker.containers.<name>` becomes one ordinary `systemd.services.<name>`:

```ini
[Unit]
After=docker.service docker.socket backend-network.service network-online.target
Requires=docker.socket backend-network.service
StartLimitBurst=3
StartLimitIntervalSec=600

[Service]
ExecStartPre=-"/usr/bin/docker" "rm" "--force" "web"
ExecStart="/usr/bin/docker" "run" "--name=web" "--pull=missing" "--rm" "--log-driver=journald" \
  "--network=backend" "--publish=127.0.0.1:8080:80" "--health-cmd=curl -f http://localhost/health" \
  ... "docker.io/library/nginx:1.27@sha256:..."
ExecStop=-"/usr/bin/docker" "stop" "--time" "10" "web"
ExecStopPost=-"/usr/bin/docker" "rm" "--force" "web"
Restart=on-failure
TimeoutStartSec=0
TimeoutStopSec=40
```

Four details in there are decisions, not boilerplate:

- **`Requires=docker.socket`, not `docker.service`.** Requiring the socket starts the socket, and
  the client's first connection to it activates the daemon. Requiring the service would force the
  daemon up in every transaction that touched this unit, which is the opposite of what
  `daemon.onBoot = false` is for.
- **Every argument is JSON-quoted, including the executable.** `ExecStart=` is not a shell; systemd
  does its own unquoting and expands `%`-specifiers. A `--health-cmd` with spaces would otherwise
  split into four arguments. The `-` prefix in front of a quoted path was checked against real
  systemd (`systemd-analyze verify`, exit 0; and exit 1 with a bogus path, so the check is not
  vacuous) -- see [`docs/gotchas.md`](docs/gotchas.md).
- **`TimeoutStopSec` is above `docker stop --time`, by a margin.** If systemd gave up on the stop
  first it would kill the client and leave the container running with nothing supervising it.
- **`TimeoutStartSec=0`.** A first start whose image is not local includes the pull, and how long
  that takes is a fact about a registry and a link.

## The daemon

The part with no counterpart in the podman sibling at all: podman is daemonless, so "install
podman" and "run containers" are one statement. Docker is a daemon that owns the lifecycle, the
socket, the storage root, and the packet-filter rules.

```nix
nixdocker.daemon = {
  enable = true;                    # DEFAULT false -- see below
  onBoot = false;                   # socket-activated instead of resident
  firewallBackend = "nftables";     # or null (docker's own default: iptables)
  dataRoot = "/var/lib/docker";
  settings = { };                   # free-form daemon.json, docker's own key names
};
```

`enable = false` is the default and it means what it says on both planes:

- **NixOS**: `virtualisation.docker` is left entirely untouched -- not set to `false`, simply not
  mentioned -- so nothing about docker is installed by this module.
- **system-manager**: the distro owns the docker package and its `docker.service`. This module never
  writes a unit of that name (it *cannot* drop into one it did not provide -- see
  [`docs/gotchas.md`](docs/gotchas.md)); `enable = true` installs a `nixdocker-daemon.target` of its
  own carrying `Requires=docker.service`, which is how a unit tree you do own pulls in a unit you do
  not.

**Declaring a container makes `enable = true` mandatory**, by assertion, naming the containers. That
is not pedantry: every container unit carries `Requires=docker.socket`, so a declared container
brings the daemon up regardless. Leaving `enable` false would not keep docker off the host, it
would only keep that fact out of the config.

### `firewallBackend`, and the iptables question

The one option here that is a decision about a host rather than a preference. Left `null`, a
starting daemon programs its `DOCKER` / `DOCKER-USER` / `DOCKER-ISOLATION-STAGE-*` chains through
the **iptables** interface -- which on a modern distro means the nf_tables-backed compatibility
shim, and still means that shim has to be installed. Set to `"nftables"`, the daemon programs
native nft tables instead, shelling out to `nft`.

The vocabulary is confirmed directly from the `dockerd` 29.7.1 binary (the `firewall-backend`
daemon.json key, the `nftables` value, the `invalid firewall-backend` rejection, the `Failed to find
nft tool` diagnostic, and its own `nftables is incompatible with swarm mode` restriction). **The
behaviour is not confirmed by anything here** -- nothing in this repo has started a daemon. Hence
`null` as the default: this repo recommends a value in prose and does not set one behind a host's
back. [`docs/gotchas.md`](docs/gotchas.md) has the full table.

## Rootless

There is no `rootless` option, and its absence is a modelling decision rather than a gap.

Rootless **podman** is a per-object property: podman is daemonless, so a uid simply runs its own
containers under its own `--user` manager, and nixpods carries a per-container `rootless.uid` for
exactly that. Rootless **docker** is a whole second daemon per user -- `dockerd-rootless.sh` under
rootlesskit, its own socket, its own storage root, its own `systemd --user` unit. That is a property
of a host, not of a container, and copying a per-container flag here would have modelled something
docker does not have.

A host that wants rootless docker wants a second `nixdocker.daemon`-shaped thing, which this repo
does not yet have. That is an open question, not a hidden feature -- see
[`experiments/README.md`](experiments/README.md).

## Two planes, one declaration

nixdocker runs on NixOS (`nixosModules.nixdocker`) and on a foreign distro through system-manager
(`systemManagerModules.nixdocker`). A container is declared the same way on either.

`modules/nixdocker.nix` holds everything true on both planes. Each backend adds only what cannot be
shared:

| | NixOS (`modules/nixos.nix`) | system-manager (`modules/system-manager.nix`) -- **the live one** |
|---|---|---|
| docker | `virtualisation.docker.enable`, and units point at that package's own store path | the distro's own package; units point at `nixdocker.docker.path` (`/usr/bin/docker`) |
| checking docker exists | the store path is the proof | a **pre-activation assertion** -- no build can prove a path outside the store exists |
| `daemon.json` | handed to `virtualisation.docker.daemon.settings`, which already owns that file | written directly through `environment.etc`, because nothing else on this plane owns it |
| starting the daemon | `virtualisation.docker.enableOnBoot` | a nixdocker-owned target with `Requires=docker.service`; this config never writes `docker.service` itself |

One option here where the podman sibling needs two: nixpods carries both a `podman.package` (whose
quadlet binary translates at build time) and a `podman.path` (what the generated unit invokes), and
has to warn that the two want to stay on the same major version. No translation happens here at all,
so there is exactly one docker involved and no skew to guard against.

## Why this is not a `nixpods` backend

The two repos looked identical to begin with, because nixdocker started life as a copy of nixpods
with a renamed token -- a copy that shipped podman in everything but the name. Three designs were
possible: a docker backend inside nixpods keyed by engine, nixdocker consuming nixpods' library as a
flake input, or two separate repos. This is the third, for three reasons:

1. **Almost nothing is actually shared.** nixpods' `lib/build.nix`, `lib/render.nix` and its
   container/pod/network/volume modules exist to feed podman's quadlet generator INI text. None of
   that survives contact with docker, which has no generator, no quadlet, no pods, and no need for a
   volumes module. What remains genuinely common is roughly ninety lines of option fragments (image
   pinning, restart/backoff, `wantedBy`, `restartIfChanged`), whose prose has to be written in each
   engine's own vocabulary anyway.
2. **An engine-keyed nixpods would contain a code path where its own thesis is false.** "Run the
   real generator at build time" is the sentence nixpods is built around; a docker branch would be
   an exception to it living inside it. It would also put a docker daemon option surface on every
   host that imports nixpods -- which, in this author's deployment, is deliberately the hosts that
   must not have docker.
3. **A flake input would couple two leaf repos for those ninety lines.** In this family, every
   cross-repo input runs aggregator -> leaf (`nixnas` -> `nixram`/`nixboot`/`nixluks`/`nixfs`); no
   leaf takes another leaf. Ninety duplicated lines with a comment naming the counterpart is the
   cheaper of the two mistakes, and `lib/options.nix`'s own header carries that comment.

## Boundaries

**vs. k3s** -- k3s is the default for services. nixdocker is for workloads that are single-host **by
nature** -- real local state, a hardware dependency, an identity tied to one machine -- and, above
all, for a **development workstation**, where docker is a mainstay of the toolchain rather than a
deployment target.

**vs. `nixpods`** -- podman is the answer for anything that is meant to keep running unattended on a
server: it is daemonless, its units are produced by a real translator at build time, and it needs no
resident privileged process. Reach for nixdocker when what you need is *docker specifically*
(a Compose-adjacent workflow, an image or tool that assumes the docker socket) on a machine where
that is the point.

**vs. `virtualisation.oci-containers`** -- on NixOS, `oci-containers` with `backend = "docker"` does
substantially what this repo's container module does, and does it well; if a host is NixOS and needs
nothing else here, use it. What nixdocker adds is the plane it does not run on (system-manager), the
daemon surface (`daemon.json`, the firewall backend, off-by-default), and the two policies
`oci-containers` deliberately leaves open: digest pinning enforced by assertion, and the refusal of
a second supervisor.

**vs. Compose** -- not modelled, and not planned. A `docker-compose.yml` is its own declarative
format with its own lifecycle; wrapping it in Nix options would produce a second, worse dialect of
it. The compose CLI is a development tool the distro installs, and this repo has no opinion about
it.

## Usage

```nix
{
  inputs.nixdocker.url = "github:julian-corbet/nixdocker-corbet-ch";

  outputs = { self, nixpkgs, nixdocker, ... }: {
    # ...or nixdocker.systemManagerModules.default, which is the plane this is deployed on.
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixdocker.nixosModules.default
        {
          nixdocker.daemon = {
            enable = true;
            onBoot = false;
            firewallBackend = "nftables";
          };

          nixdocker.networks.backend.subnet = "172.28.0.0/16";

          nixdocker.containers.web = {
            image = {
              repository = "docker.io/library/nginx";
              tag = "1.27";
              digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
            };
            networks = [ "backend" ];
            ports = [ "127.0.0.1:8080:80" ];
            volumes = [ "/srv/example/data:/data" ];
            health.cmd = "curl -f http://localhost/health";
          };
        }
      ];
    };
  };
}
```

Docker declared and configured but not running -- the default this repo was scoped to produce -- is
simply the same import with no `daemon.enable` and no containers:

```nix
nixdocker.daemon.firewallBackend = "nftables";   # daemon.json in place, nothing started
```

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point: `nixosModules.nixdocker` / `systemManagerModules.nixdocker` / `.default`, the pure `lib.*`, and `checks`. |
| `modules/containers.nix` | `nixdocker.containers.<name>` -- the main policy-bearing option surface. |
| `modules/networks.nix` | `nixdocker.networks.<name>` -- create-if-absent, the one imperative corner, and its own header says why there is no volumes module. |
| `modules/daemon.nix` | `nixdocker.daemon` -- the daemon lifecycle and `daemon.json`. No counterpart in the podman sibling. |
| `modules/nixdocker.nix` | The wiring that is true on every plane: renders each argv, composes the units, orders them against the daemon and the networks. |
| `modules/nixos.nix` / `modules/system-manager.nix` | The two thin per-plane backends; each header says exactly what it adds and why that part could not be shared. |
| `lib/render.nix` | The pure typed-option -> `docker run` argv translation, plus the vendored systemd exec escaping. |
| `lib/options.nix` | Option fragments shared by both kinds, and the header explaining the deliberate parallel with nixpods. |
| `docs/gotchas.md` | The empirical findings this design is built on -- transcripts, not assertions, and explicit about which came from running something and which from reading a binary. |
| `checks/default.nix` | Pure render tests, NixOS eval tests, and one real build that reads a generated unit file back. |
| `checks/system-manager-eval-tests.nix` | The live plane, evaluated through system-manager's own `makeSystemConfig` -- and its `/etc/systemd/system` tree built and read back. |
| `experiments/` | Open judgment calls, not yet settled -- see [`experiments/README.md`](experiments/README.md). |
| `studies/` | Written-up findings that changed a decision -- see [`studies/README.md`](studies/README.md). |

## Status

Both planes, the container and network surfaces, and the daemon surface are implemented and covered
by `nix flake check`:

- eval-time assertions, on both planes -- an unpinned image, a malformed digest, a dangling network
  reference, a `--restart` smuggled through `extraArgs`, a container declared while the daemon is
  off, two objects resolving to one unit name, and a `Type=oneshot` unit with a `Restart=` systemd
  would refuse to load: each fails evaluation by name;
- pure render tests against the argv, including the ordering fact that decides whether a flag
  reaches docker or the container's own process, and the systemd escaping of a spaced value and a
  `%` specifier;
- two real builds: a generated `.service` read back off disk on the NixOS plane, and the whole
  `/etc/systemd/system` tree built and read back on the system-manager plane -- including that the
  distro's `docker.service` is *not* in it.

`systemd-analyze verify` was run against a generated unit empirically, live, outside the Nix build
sandbox (which has no writable `/run` for it to use) -- see [`docs/gotchas.md`](docs/gotchas.md) for
that transcript; it is not re-invoked by `nix flake check`.

**Not done, deliberately**: rootless docker (a second daemon, not a flag -- see above), Compose,
and any form of network reconciliation. Nothing in this repo has ever started a docker daemon, and
the first host to set `firewallBackend` is the test of that option.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
