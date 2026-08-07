# modules/nixos.nix
#
# The NixOS plane. `modules/nixdocker.nix` next to this file already did everything that is true on
# every plane -- rendered each container's argv, wrote the units, wired the network dependencies
# and the ordering against the daemon. This file adds only what does not exist anywhere else:
#
#   1. docker itself, via `virtualisation.docker.*` -- a NixOS-only module namespace, and the
#      reason a foreign-distro host needs `nixdocker.docker.path` instead;
#   2. `/etc/docker/daemon.json`, which on this plane is NOT written directly: NixOS's own
#      `virtualisation.docker.daemon.settings` already owns that file, and two writers for one
#      path is a conflict rather than a merge.
#
# This is the plane nixdocker is NOT deployed on today -- the operator scoped this repo to one
# workstation, and that workstation runs a foreign distro, so `modules/system-manager.nix` is the
# live backend. This one exists because a module repo that only works on the plane it happens to
# be used on is a module repo whose plane-independence was never tested, and because the checks
# evaluate both.
{ lib, config, ... }:

let
  cfg = config.nixdocker;
in
{
  imports = [ ./nixdocker.nix ];

  config = lib.mkMerge [
    {
      # UNCONDITIONAL, deliberately: gate this on "is anything declared" and the module system
      # deadlocks -- answering that question means building the unit definitions, and the units are
      # built around this very path. Setting it always costs nothing on a host that declares no
      # containers, and it does not itself pull docker into the closure: reading a package's own
      # store path is an evaluation, not an installation.
      nixdocker.docker.path = lib.mkDefault "${config.virtualisation.docker.package}/bin/docker";
    }

    # NOTHING AT ALL WHEN THE DAEMON IS OFF. `virtualisation.docker` is left entirely untouched --
    # not set to `false`, which would fight a host that turned it on for its own reasons, simply not
    # mentioned. That is what "declared and installable, but not running" means on this plane: the
    # option surface exists, the package does not get installed, and nothing is masked.
    (lib.mkIf cfg.daemon.enable {
      virtualisation.docker = {
        enable = true;
        enableOnBoot = cfg.daemon.onBoot;

        # `daemon.settings` is a `pkgs.formats.json` freeform submodule upstream, so this merges
        # with anything the host set there directly rather than replacing it -- and a genuine
        # conflict on one key is reported by the module system by name, which is the right outcome.
        daemon.settings = cfg.daemon.settingsFile;
      };
    })
  ];
}
