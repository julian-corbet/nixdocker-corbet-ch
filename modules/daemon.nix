# modules/daemon.nix
#
# `nixdocker.daemon` -- the part of this repo that has no counterpart in its podman sibling at all.
#
# PODMAN IS DAEMONLESS. A podman container is a child of the systemd unit that started it, so
# "install podman" and "run containers" are one statement. DOCKER IS A DAEMON: `docker run` is an
# API client, the container is a child of `dockerd`/`containerd`, and the daemon owns the
# lifecycle, the storage root, the socket, the group that may reach it, and -- the one that
# matters most on a host with its own firewall -- the packet-filter rules that make published
# ports and container egress work at all. None of that is per-container, so none of it belongs in
# modules/containers.nix.
#
# OFF BY DEFAULT, AND THAT IS THE POINT. `enable` is `false`, so importing this module gives a
# host the option surface and nothing running. The reasoning is the operator's: docker is a
# development mainstay on a workstation and has no business being a resident daemon anywhere else,
# so "declared and installable" and "running" are deliberately two different statements here.
# Declaring a container is the one thing that makes them the same statement -- and that is an
# assertion (below), not a silent implication.
{ lib, config, ... }:

let
  cfg = config.nixdocker.daemon;

  # The typed knob and the freeform escape hatch must not both claim the same daemon.json key --
  # `settings` wins nothing and loses nothing, it is simply refused, because "which of these two
  # did the daemon actually read" is not a question a host should have to answer by experiment.
  firewallBackendKey = "firewall-backend";
in
{
  options.nixdocker.daemon = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether `dockerd` runs on this host.

        DEFAULT `false`, DELIBERATELY. Importing nixdocker declares the option surface; it does
        not start a container engine. A host says `true` here when it actually wants a resident
        docker daemon -- which, in this repo's intended deployment, is a development workstation
        and nothing else.

        WHAT THIS MEANS PER PLANE, because the two are genuinely different:

        - NixOS (`modules/nixos.nix`): this drives `virtualisation.docker.enable`, so it installs
          the package and wires the units too. `false` leaves `virtualisation.docker` entirely
          untouched, so nothing about docker is installed by this module.
        - system-manager on a foreign distro (`modules/system-manager.nix`): the distro owns the
          docker package and its `docker.service`/`docker.socket`, and this config does not write
          either. `true` installs a nixdocker-owned target that `Requires=docker.service`, which
          is how a unit tree you do own pulls in a unit you do not. `false` installs no such
          target and the distro's own default (on Arch: docker.service ships disabled) stands.

        Either way this option never MASKS or stops a daemon a host already started by hand --
        `false` means "nothing here asks for it", not "nothing here may have it".
      '';
    };

    onBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the daemon starts at boot, as opposed to on first use of its socket. Only
        meaningful when `enable` is true.

        `false` leaves docker socket-activated: the socket unit listens, and the first client to
        connect starts the daemon. That is the leaner shape for a workstation where docker is used
        some days and not others. The one thing it breaks is a container carrying the daemon's own
        `--restart` policy, which needs the daemon up to act on -- and this repo never emits one
        (see modules/containers.nix's assertion), so nothing here depends on it.
      '';
    };

    firewallBackend = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "iptables" "nftables" ]);
      default = null;
      example = "nftables";
      description = ''
        Which packet-filter interface the daemon programs its own rules through
        (`firewall-backend` in daemon.json). `null` (the default) says nothing and leaves docker's
        own default, which is `iptables`.

        THIS IS THE OPTION THAT DECIDES WHETHER DOCKER CAN COEXIST WITH AN nftables-NATIVE HOST.
        Left at `null`, a starting daemon programs its DOCKER / DOCKER-USER /
        DOCKER-ISOLATION-STAGE-* chains through the iptables interface -- which, on a modern
        distro whose `iptables` binary is the nf_tables-backed compatibility shim, still means an
        `ip filter`/`ip nat` table in iptables' own legacy-shaped namespace, and still means the
        host needs that shim installed. Set to `"nftables"` and the daemon programs native nft
        tables instead, shelling out to the `nft` tool.

        VERIFIED, AND THE LIMIT OF WHAT WAS VERIFIED: the `firewall-backend` key, the `nftables`
        value, the daemon's `invalid firewall-backend` rejection of anything else, its "Failed to
        find nft tool" diagnostic, and its own "nftables is incompatible with swarm mode" are all
        read directly out of the `dockerd` binary shipped as docker 29.7.1. That is a strong
        statement about the vocabulary and no statement at all about behaviour: nothing in this
        repo has run either backend. Treat the first host to set this as the test, and see
        docs/gotchas.md.
      '';
    };

    dataRoot = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/docker";
      description = ''
        Where the daemon keeps images, layers and container state (`data-root` in daemon.json).
        `null` leaves docker's own default, `/var/lib/docker`.

        Worth setting explicitly on a host where `/var` is on a filesystem that is small, or is a
        snapshotted subvolume somebody will later be surprised to find holds forty gigabytes of
        image layers.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      example = { log-driver = "journald"; "default-address-pools" = [{ base = "172.30.0.0/16"; size = 24; }]; };
      description = ''
        Free-form `/etc/docker/daemon.json` content, merged under the typed options above. Keys are
        docker's own, verbatim and hyphenated -- this is not a Nix-flavoured renaming layer, and a
        typo is a key the daemon ignores.

        The typed options above (`firewallBackend`, `dataRoot`) write into this same document, and
        setting one of them AND its raw key here is refused by assertion rather than silently
        resolved.
      '';
    };

    # ── computed, read-only: the document the per-plane backends actually install ─────────────
    settingsFile = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      internal = true;
      readOnly = true;
      description = "The merged daemon.json document: `settings` plus whatever the typed options above contribute.";
    };
  };

  config = {
    nixdocker.daemon.settingsFile =
      cfg.settings
      // lib.optionalAttrs (cfg.firewallBackend != null) { ${firewallBackendKey} = cfg.firewallBackend; }
      // lib.optionalAttrs (cfg.dataRoot != null) { data-root = cfg.dataRoot; };

    assertions = [
      {
        assertion = cfg.firewallBackend == null || !(cfg.settings ? ${firewallBackendKey});
        message = ''
          nixdocker.daemon: both firewallBackend and settings."${firewallBackendKey}" are set. They
          write the same daemon.json key, and which one a host actually got would depend on merge
          order rather than on anything anybody wrote down. Keep the typed option -- it is an enum,
          so a typo fails here instead of making the daemon exit with "invalid firewall-backend" on
          its next start -- and drop the raw key.
        '';
      }
      {
        assertion = cfg.dataRoot == null || !(cfg.settings ? data-root);
        message = ''
          nixdocker.daemon: both dataRoot and settings."data-root" are set. They write the same
          daemon.json key; keep one. Moving this path is also not a rename -- the daemon does not
          migrate its existing images and containers to a new root, it starts empty there.
        '';
      }
      {
        assertion = cfg.enable || config.nixdocker.containers == { };
        message = ''
          nixdocker: containers are declared
          (${lib.concatStringsSep ", " (lib.attrNames config.nixdocker.containers)}) while
          nixdocker.daemon.enable is false (its default).

          Every container unit this repo generates carries Requires=docker.socket, because that is
          what makes a container start work whether the daemon is already up or is socket-activated
          on first connect. So a declared container DOES bring the daemon up -- which means leaving
          daemon.enable false here would not keep docker off this host, it would only keep that
          fact out of the config. Set nixdocker.daemon.enable = true and say it out loud, or drop
          the containers.
        '';
      }
      {
        assertion = cfg.enable || config.nixdocker.networks == { };
        message = ''
          nixdocker: networks are declared
          (${lib.concatStringsSep ", " (lib.attrNames config.nixdocker.networks)}) while
          nixdocker.daemon.enable is false (its default). A network's create-if-absent unit talks
          to the daemon exactly like a container does, and pulls it in the same way. Set
          nixdocker.daemon.enable = true, or drop the networks.
        '';
      }
    ];
  };
}
