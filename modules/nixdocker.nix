# modules/nixdocker.nix
#
# THE WIRING, and everything about it that is TRUE ON EVERY PLANE. The other modules in this
# directory only declare typed options; this file is the one place that actually turns them into
# `systemd.services.<name>` definitions:
#
#   1. renders each container's full `docker run` argv (lib/render.nix) and each network's
#      create-if-absent script,
#   2. writes them into ordinary systemd service definitions -- `ExecStartPre` to clear a leftover
#      container of the same name, `ExecStart` for the foreground run, `ExecStop`/`ExecStopPost`
#      for the stop and the sweep,
#   3. wires each container's `Requires=`/`After=` onto the units of the networks it references,
#      so a network exists before the container that needs it, and
#   4. orders everything after the daemon: `Requires=docker.socket` plus `After=docker.service
#      docker.socket`.
#
# WHY `Requires=docker.socket` AND NOT `Requires=docker.service`. The socket is what makes this
# work on a host where the daemon is not running at boot: requiring the socket starts the socket,
# and the first connection the `docker` client makes to it is what activates the daemon. Requiring
# the service instead would force the daemon up in the transaction even when nothing else wanted
# it, which is the opposite of what `nixdocker.daemon.onBoot = false` is for.
#
# WHY THERE IS NO lib/build.nix HERE, unlike in this repo's podman sibling. nixpods has one
# because podman ships a real systemd generator (its `quadlet` binary) that nixpods runs inside
# the Nix build sandbox: the units it installs were produced by the same translator that would
# otherwise run at boot, and a malformed input fails the build because that translator looked at
# it. Docker ships nothing of the kind -- no generator, no quadlet, nothing under
# `lib/systemd/system-generators/` -- so there is no earlier translator to move; this file writes
# the units itself, and what it can promise is correspondingly narrower. The README says so in its
# own section rather than letting the resemblance imply otherwise.
#
# Nothing here ever runs docker, starts a container, or touches the network at build time.
{ lib, config, pkgs, ... }:

let
  cfg = config.nixdocker;
  render = import ../lib/render.nix { inherit lib; };

  enabledContainers = lib.filter (c: c.enable) (lib.attrValues cfg.containers);
  enabledNetworks = lib.filter (n: n.enable) (lib.attrValues cfg.networks);

  anythingDeclared = enabledContainers != [ ] || enabledNetworks != [ ];

  # docker's three built-in networks exist without a unit, so a reference to one contributes no
  # dependency -- only a declared `nixdocker.networks.<name>` does. modules/containers.nix has
  # already asserted that every reference is one or the other.
  networkUnitsFor = container:
    map (n: "${cfg.networks.${n}.serviceName}.service")
      (lib.filter (n: cfg.networks ? ${n}) container.networks);

  # The docker binary is named in full, by absolute path, in every Exec* line. `escapeSystemdExecArg`
  # is applied to it as well as to the arguments -- systemd accepts a quoted executable path (this
  # is what nixpkgs' own modules do with `utils.escapeSystemdExecArgs`, applied to a list whose
  # head is the binary), and skipping it would leave the one string this repo does not control the
  # shape of unescaped.
  dockerArgs = args: render.escapeSystemdExecArgs ([ cfg.docker.path ] ++ args);

  # A leading `-` tells systemd to ignore a non-zero exit. Both places it is used here are sweeps
  # whose failure is the NORMAL case: `docker rm --force <name>` exits non-zero when there is no
  # such container, which is exactly the state a healthy host is in before every start.
  mkContainerService = c: lib.nameValuePair c.serviceName ({
    description = "nixdocker container ${c.containerName}";

    wantedBy = c.wantedBy;
    inherit (c) restartIfChanged;

    requires = [ "docker.socket" ] ++ networkUnitsFor c;
    after = [ "docker.service" "docker.socket" ]
      ++ networkUnitsFor c
      ++ lib.optional c.waitForNetworkOnline "network-online.target";
    wants = lib.optional c.waitForNetworkOnline "network-online.target";

    unitConfig = {
      StartLimitBurst = c.restart.startLimitBurst;
      StartLimitIntervalSec = c.restart.startLimitIntervalSec;
    } // c.extraUnitConfig;

    serviceConfig = {
      ExecStartPre = "-" + dockerArgs [ "rm" "--force" c.containerName ];
      ExecStart = render.escapeSystemdExecArgs (render.mkRunArgv {
        docker = cfg.docker.path;
        name = c.containerName;
        cfg = c;
      });
      ExecStop = "-" + dockerArgs [ "stop" "--time" (toString c.stopTimeout) c.containerName ];
      ExecStopPost = "-" + dockerArgs [ "rm" "--force" c.containerName ];

      Restart = c.restart.policy;
      RestartSec = c.restart.restartSec;

      # `TimeoutStartSec=0` (no limit) because the first start of a container whose image is not
      # yet local includes the pull, and how long that takes is a fact about a registry and a link,
      # not about this unit. nixpkgs' own oci-containers module reaches the same conclusion.
      TimeoutStartSec = 0;

      # Above `docker stop --time`, on purpose and by a real margin: systemd must not give up on
      # the stop while docker is still waiting out the grace period it was told to give the
      # container. If systemd killed the client first, the container would be left running with
      # nothing supervising it.
      TimeoutStopSec = c.stopTimeout + 30;
    }
    // lib.optionalAttrs c.oneshot { Type = "oneshot"; }
    // c.extraServiceConfig;
  });

  mkNetworkService = n: lib.nameValuePair n.serviceName {
    description = "nixdocker network ${n.networkName} (create if absent)";

    wantedBy = n.wantedBy;
    inherit (n) restartIfChanged;

    requires = [ "docker.socket" ];
    after = [ "docker.service" "docker.socket" ];

    serviceConfig = {
      Type = "oneshot";
      # The containers that reference this network carry `Requires=` on it, and a Requires= on a
      # oneshot unit that has already run is only satisfied while the unit counts as active --
      # which for a oneshot means RemainAfterExit.
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "nixdocker-network-${n.networkName}" (render.mkNetworkScript {
        docker = cfg.docker.path;
        name = n.networkName;
        cfg = n;
      })}";
    };
  };

  # ── cross-kind sanity: a property of the WHOLE collection, not of any one kind ──────────────
  duplicateServiceNames =
    let
      names = map (o: o.serviceName) (enabledContainers ++ enabledNetworks);
      counts = lib.foldl' (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; }) { } names;
    in
    lib.attrNames (lib.filterAttrs (_: count: count > 1) counts);
in
{
  imports = [
    ./containers.nix
    ./networks.nix
    ./daemon.nix
  ];

  options.nixdocker.docker = {
    path = lib.mkOption {
      type = lib.types.str;
      example = "/usr/bin/docker";
      description = ''
        Absolute path to the `docker` CLI every generated unit invokes.

        ONE OPTION HERE, WHERE THE PODMAN SIBLING NEEDS TWO, and the asymmetry is the mechanism
        difference showing through. nixpods carries both a `podman.package` (the nix package whose
        quadlet binary translates at BUILD time) and a `podman.path` (the binary the generated unit
        names at RUN time), and has to warn that the two want to stay on the same major version. No
        translation happens here at all, so there is exactly one docker involved and no skew to
        guard against.

        Each per-plane backend sets its own default: the NixOS backend points this at
        `virtualisation.docker.package`'s own store path, the system-manager backend at
        `/usr/bin/docker`, which is the distro's. Nothing at build time can prove a path outside
        the store exists, so the system-manager backend also registers a pre-activation assertion
        for it -- the earliest a foreign path can honestly be checked at all.
      '';
    };
  };

  # ── computed, read-only: what the per-plane backends next to this file install ──────────────
  options.nixdocker.build = {
    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      internal = true;
      readOnly = true;
      description = "The `systemd.services` definitions this config produces, keyed by service name.";
    };
    anythingDeclared = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      readOnly = true;
      description = "Whether any enabled container or network is declared at all -- how a backend asks whether it has work to do.";
    };
  };

  config = lib.mkMerge [
    # Defined unconditionally, not under the `mkIf` below: these are how the per-plane backends ask
    # "is there anything to install, and what", so they have to answer honestly on a host that
    # declared nothing. (They carry no `default` either -- nixpkgs counts an option's default as one
    # of its definitions, and a `readOnly` option with both a default and an assignment is refused
    # as "set multiple times".)
    {
      nixdocker.build = {
        services = lib.listToAttrs (map mkContainerService enabledContainers)
          // lib.listToAttrs (map mkNetworkService enabledNetworks);
        anythingDeclared = anythingDeclared;
      };
    }

    (lib.mkIf anythingDeclared {
      systemd.services = cfg.build.services;

      assertions = [
        {
          assertion = duplicateServiceNames == [ ];
          message = ''
            nixdocker: more than one declared object resolves to the same systemd service name
            (${lib.concatStringsSep ", " duplicateServiceNames}). A network called <n> takes
            "<n>-network", so a container literally named "<n>-network" collides with it -- every
            declared object across nixdocker.containers and nixdocker.networks must produce a
            unique <serviceName>.service. Rename one of the colliding objects.
          '';
        }
      ];
    })
  ];
}
