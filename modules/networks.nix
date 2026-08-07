# modules/networks.nix
#
# `nixdocker.networks.<name>` -- a named docker network, pre-created by a unit rather than by
# whichever container happened to reference it first.
#
# WHY THIS MODULE EXISTS WHEN THERE IS NO `nixdocker.volumes`. The two are not symmetric, which is
# a fact about docker rather than a choice here: `docker run --volume=somename:/data` creates
# `somename` if it does not exist, while `docker run --network=somenet` FAILS if `somenet` does
# not exist ("network somenet not found"). So a network genuinely needs somebody to create it, and
# a volume genuinely does not.
#
# AND WHY IT IS THE ONE IMPERATIVE CORNER OF THIS REPO. `docker network` has `create` and
# `inspect` and no apply/reconcile verb at all, so "make sure this exists" is a conditional create
# -- see lib/render.nix's `mkNetworkScript`, which says out loud, in the unit's own output, that a
# network that already exists is left exactly as it is. Changing a subnet in Nix does not move a
# live network. That is a real limitation of this module and it is written down rather than
# implied; the README's "What this repo cannot promise" section carries it too.
{ lib, ... }:

let
  opts = import ../lib/options.nix { inherit lib; };

  networkType = lib.types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this network's unit is generated and installed at all.";
      };

      driver = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "bridge" "macvlan" "ipvlan" "overlay" "none" ]);
        default = null;
        description = ''
          `docker network create --driver`. `null` (the default) leaves docker's own default
          (`bridge`) in place.

          `overlay` is listed because docker accepts it, not because this repo supports what it
          implies: an overlay network needs swarm mode, which is a cluster, which is the boundary
          the README draws against k3s. A single-host declaration reaching for it is almost
          certainly the wrong tool.
        '';
      };

      subnet = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "172.28.0.0/16";
        description = ''
          `--subnet`. `null` leaves docker's own IPAM allocation in place -- which is the honest
          default, but note that docker's automatic pool can collide with a real network the host
          is on, and this module cannot see that. Pin a subnet when the host has other routes that
          matter.
        '';
      };

      gateway = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "`--gateway`. Only meaningful alongside `subnet`.";
      };

      internal = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Restrict this network from reaching outside the host (`--internal`): no default route, no masquerade rule.";
      };

      ipv6 = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable IPv6 on this network (`--ipv6`).";
      };

      restartIfChanged = opts.restartIfChangedOption;

      # `[ ]` on purpose: a network is pulled in by the containers that reference it (see
      # modules/nixdocker.nix, which wires a real Requires=/After= for exactly that), so being
      # wanted by a target as well is redundant for the normal case. A host that wants the network
      # to exist with no container running yet can set this itself.
      wantedBy = opts.wantedByOption [ ];

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--opt" "com.docker.network.bridge.name=br-example" ];
        description = "Extra raw `docker network create` flags, appended before the network name.";
      };

      # ── computed, read-only -- consumed by modules/nixdocker.nix ────────────────────────────
      serviceName = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        description = "The systemd service name (without .service) this network's create-if-absent unit becomes.";
      };
      networkName = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        description = "The name docker itself knows this network by.";
      };
    };

    config = {
      # Suffixed, not bare: a network and a container may legitimately share a name in a host's
      # own head ("backend"), and two objects resolving to one `.service` would be a collision
      # nobody asked for. modules/nixdocker.nix still asserts on the resolved names, because a
      # container literally called `backend-network` would collide with this.
      serviceName = "${name}-network";
      networkName = name;
    };
  });
in
{
  options.nixdocker.networks = lib.mkOption {
    type = lib.types.attrsOf networkType;
    default = { };
    description = ''
      Docker networks declared as create-if-absent systemd units. Referencing one from
      `nixdocker.containers.<name>.networks` gets a real `Requires=`/`After=` on its unit, so the
      network is created before the container that needs it starts.
    '';
  };
}
