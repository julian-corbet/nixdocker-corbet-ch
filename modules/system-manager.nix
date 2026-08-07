# modules/system-manager.nix
#
# The system-manager plane: a foreign distro (Arch, Debian, Ubuntu) whose systemd this config
# writes units into without owning the OS underneath. THIS IS THE LIVE BACKEND for this repo --
# the one workstation nixdocker is scoped to runs a foreign distro, so everything below is the
# path that actually gets deployed, not the theoretical one.
#
# `modules/nixdocker.nix` next to this file already did the real work, and it genuinely is the same
# work here: system-manager implements `systemd.services` through nixpkgs' own systemd unit types
# (it imports `nixos/lib/utils.nix` and the upstream unit schema outright), so a service definition
# written once renders on both planes with no translation table.
#
# What this file adds is the four things that are NOT the same, each of them a place where assuming
# NixOS would have produced a silent failure rather than an error:
#
#   1. DOCKER IS THE DISTRO'S, NOT THIS CONFIG'S. There is no `virtualisation.docker` here -- that
#      namespace does not exist on this plane -- so the generated units are pointed at
#      `/usr/bin/docker` and the distro keeps ownership of the package, its `docker.service`, its
#      `docker.socket` and its `docker` group.
#
#   2. NOTHING AT BUILD TIME CAN PROVE A PATH OUTSIDE THE STORE EXISTS. "is docker installed on
#      that host" is not a question a build can answer about a foreign distro. The earliest honest
#      answer is system-manager's own pre-activation assertion hook, which runs on the target
#      before anything is switched: a host without docker fails its deploy, by name, instead of
#      leaving units behind that cannot start.
#
#   3. `/etc/docker/daemon.json` IS WRITTEN HERE, DIRECTLY. On NixOS that file belongs to
#      `virtualisation.docker.daemon.settings`; on this plane nothing owns it, so this backend
#      writes it through `environment.etc`. Two things follow that a host should know: the file is
#      replaced wholesale rather than merged with whatever was there before, and the daemon only
#      reads it at START, so changing it through a deploy does nothing until docker is restarted.
#
#   4. ENABLING THE DAEMON MEANS PULLING IN A UNIT THIS CONFIG DOES NOT OWN. nixdocker must not
#      write `docker.service`: system-manager's etc builder installs a Nix-side unit definition as
#      a drop-in only when some `systemd.packages` entry already provided a file of that name, and
#      nothing here provides one -- so defining `systemd.services.docker` would land a REPLACEMENT
#      unit in `/etc/systemd/system/docker.service`, shadowing the distro's own (read directly out
#      of `nix/modules/systemd.nix`'s etc builder, not assumed). The way a unit tree you do own
#      pulls in a unit you do not is an ordinary dependency: this backend installs a target of its
#      own that `Requires=docker.service`, and systemd resolves that by unit NAME through its
#      normal search path, where the distro's file already is.
{ lib, config, ... }:

let
  cfg = config.nixdocker;
in
{
  imports = [ ./nixdocker.nix ];

  config = lib.mkMerge [
    {
      # UNCONDITIONAL, deliberately -- same module-system deadlock as the NixOS backend's own
      # default: answering "is anything declared" means building the units, and the units are built
      # around this very path.
      nixdocker.docker.path = lib.mkDefault "/usr/bin/docker";
    }

    (lib.mkIf (cfg.build.anythingDeclared || cfg.daemon.enable) {
      system-manager.preActivationAssertions.nixdocker-docker = {
        enable = true;
        script = ''
          if [ ! -x "${cfg.docker.path}" ]; then
            echo "nixdocker: ${cfg.docker.path} is missing or not executable on this host."
            echo "Every unit nixdocker generates here invokes it by that absolute path, so activating"
            echo "would install units that cannot start. Install this distro's own docker package,"
            echo "or point nixdocker.docker.path at wherever it actually lives."
            exit 1
          fi
        '';
      };
    })

    (lib.mkIf (cfg.daemon.settingsFile != { }) {
      # Written whether or not the daemon is enabled: a host may well want its daemon.json in place
      # before it ever turns docker on, and this file is inert until dockerd reads it.
      environment.etc."docker/daemon.json" = {
        text = builtins.toJSON cfg.daemon.settingsFile;
        mode = "0644";
      };
    })

    (lib.mkIf cfg.daemon.enable {
      # `Requires=` + `After=` on a unit name this config does not own, which is the whole
      # mechanism -- see this file's header, point 4. A target rather than a service because it has
      # no work of its own to do: its entire purpose is to be wanted by the boot and to want docker
      # in turn.
      #
      # `wantedBy = [ "multi-user.target" ]` is rewritten to `system-manager.target` by
      # system-manager itself when it emits the `.wants` symlink (its `substituteTarget`), so this
      # is the correct spelling on this plane even though the directory it lands in has a different
      # name. See docs/gotchas.md.
      systemd.targets.nixdocker-daemon = {
        description = "nixdocker: this host wants the docker daemon";
        requires = [ "docker.service" ];
        after = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
      };

      system-manager.preActivationAssertions.nixdocker-dockerd = {
        enable = true;
        script = ''
          if ! systemctl cat docker.service >/dev/null 2>&1; then
            echo "nixdocker: nixdocker.daemon.enable is true, but this host has no docker.service."
            echo "This plane does not install docker -- the distro's own package owns dockerd and its"
            echo "units, and nixdocker only declares a target that Requires= it. Install the distro's"
            echo "docker package first, or set nixdocker.daemon.enable = false."
            exit 1
          fi
        '';
      };
    })
  ];
}
