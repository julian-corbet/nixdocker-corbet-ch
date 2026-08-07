# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing up properly. Nothing
here is guaranteed to work, be maintained, or survive the next cleanup pass. If something turns out
to matter, distill the finding into [`../studies/`](../studies/README.md) and let the experiment
stay disposable.

This is also the open-questions ledger for nixdocker's own judgment calls. Every entry below is a
design choice that is *reasoned*, not yet *measured* -- recorded here so the difference stays
visible. Results feed back into `modules/*.nix` and `lib/*.nix` as they close.

All open; nothing has been run yet.

## 001 -- does `firewall-backend = "nftables"` actually work, and does it coexist with an existing `inet` firewall table?

**Question:** `nixdocker.daemon.firewallBackend` is typed as an enum whose vocabulary was read out
of the `dockerd` 29.7.1 binary's string table -- the key, the `nftables` value, the `invalid
firewall-backend` rejection, the `Failed to find nft tool` diagnostic. Nothing in this repo has ever
started a docker daemon, so nothing here knows whether the nftables backend *works*, what tables it
creates, or whether those coexist cleanly with a host that already has an `inet` firewall table and
libvirt's own `ip/ip6 libvirt_network`.

**Reasoning as it stands:** ship the option with a `null` default, which says nothing and leaves
docker's own default (iptables). A repo that has not tested a value must not set it on a host's
behalf; recommending it in prose and leaving the host to choose is the honest middle.

**What would settle it:** one host sets it, starts the daemon, and `nft list ruleset` before and
after is compared -- specifically whether docker's chains land in a native table, whether the
`iptables` shim is still touched at all, and whether container egress and a published port both
still work. Until that happens, `docs/gotchas.md` is explicit that only the vocabulary is
established.

## 002 -- should rootless docker get a second daemon surface, or stay out of scope?

**Question:** this repo has no rootless option at all, because rootless docker is a whole second
daemon per user (`dockerd-rootless.sh` under rootlesskit, its own socket, its own storage root, its
own `systemd --user` unit) rather than a per-container flag the way rootless podman is. The README
says so. It does not say whether nixdocker should eventually *model* that second daemon.

**Reasoning as it stands:** leave it out. The host this repo is scoped to is a single-user
development workstation where the operator is already in the `docker` group, so rootless would buy
isolation from a threat model that is not the one in play, at the cost of a second daemon surface,
a `systemd --user` tree, and subuid/subgid management this repo would then have opinions about.

**What would settle it:** a concrete reason -- a workload on that workstation that genuinely should
not reach the root docker socket. Absent one, this stays a documented absence rather than a backlog
item.

## 003 -- is create-if-absent the right shape for networks, or should a drifted network be an error?

**Question:** `nixdocker.networks.<name>` leaves an existing network exactly as it is, because
`docker network` has `create` and `inspect` and no reconcile verb. A network whose live subnet no
longer matches the Nix declaration is therefore silently tolerated, and the unit's own output says
so rather than failing.

**Reasoning as it stands:** the alternatives are worse. Failing the unit would break every container
that depends on it over a mismatch that may be entirely harmless. Recreating it would tear down
every container attached, which is a destructive action a config file should not take on its own.
Saying so loudly, in the unit's journal, is the honest middle.

**What would settle it:** a real drift incident. If "the unit told me and I did not read it" turns
out to be the failure mode, the next step is a *separate* check that compares `docker network
inspect` output against the declaration and reports, without acting -- not a change to what the
create unit does.

## 004 -- should the container unit's `ExecStop` use `docker stop` at all, given `--sig-proxy`?

**Question:** the generated unit both relies on `docker run`'s default `--sig-proxy=true` (systemd's
SIGTERM to the client is forwarded to the container's PID 1) and carries an explicit
`ExecStop=docker stop --time <n>`. Those are two paths to the same outcome, and nixpkgs'
`oci-containers` does the same thing for its docker backend.

**Reasoning as it stands:** keep both. The signal-proxy path depends on the client still being
alive and connected; `docker stop` works even if it is not, which is the case a stop most needs to
handle. `TimeoutStopSec` is set above `--time` precisely so the explicit path has room to finish.

**What would settle it:** watching a real stop with both in place and checking the journal for a
double-stop or a delayed one. Cheap to do on the first host that runs a long-lived container here,
and not worth a synthetic test before then.
