# modules/packages.nix
#
# Declarative package intent for nixdocker consumers.
#
# nixdocker itself declares no packages beyond this -- it renders `docker run` argv into systemd
# units, and docker is the distro's own package on the plane this repo is actually deployed on
# (see modules/system-manager.nix). But `docker-compose` and `docker-buildx` are host tooling a
# docker workflow reaches for constantly -- a `compose.yml` this repo does not model, an image
# build this repo does not orchestrate -- and the operator has ruled that they belong declared
# alongside the plane that actually uses them, rather than hand-installed per host. This module is
# that one narrow exception: it does not become a general package manager, and it names nothing
# beyond the two tools below.
#
# Same shape as nixiam's own modules/packages.nix: a flat baseline, backend-mapped by the two
# sibling files next to this one.
{ config, lib, ... }:
let
  cfg = config.nixdocker.packages;
in
{
  options.nixdocker.packages = {
    # Baseline package names before backend mapping.
    baseline = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "docker" "docker-compose" "docker-buildx" ];
      defaultText = lib.literalExpression ''[ "docker" "docker-compose" "docker-buildx" ]'';
      description = ''
        Baseline packages this module declares for all nixdocker consumers, before a backend maps
        them to its concrete package source format.
      '';
    };

    # Platform-mapped outputs consumed by backends.
    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Baseline pacman package names. This keeps the public face of the policy one list while
        each backend maps to its own package source.
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Baseline AUR package names. Left empty for this policy today because both `docker-compose`
        and `docker-buildx` have an official pacman name (verified against the Arch `extra` /
        `cachyos-extra-v3` repositories).
      '';
    };

    nixosPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        NixOS package attribute names (as seen by nixpkgs). The baseline keeps these equal to
        `nixdocker.packages.baseline` for now.
      '';
    };
  };

  config.nixdocker.packages = {
    archPackages = lib.unique cfg.baseline;
    aurPackages = [ ];
    nixosPackages = lib.unique cfg.baseline;
  };
}
