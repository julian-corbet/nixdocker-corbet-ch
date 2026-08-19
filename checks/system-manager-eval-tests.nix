# checks/system-manager-eval-tests.nix
#
# THE PLANE THIS REPO IS ACTUALLY DEPLOYED ON. nixdocker is scoped to one development workstation,
# and that workstation runs a foreign distro under system-manager -- so unlike its podman sibling,
# where the NixOS plane is the primary one and this file is the second opinion, here it is the
# other way round. Everything below is the path that gets switched onto a real host.
#
# The claim under test: a container declared once renders here too, with no second declaration and
# no per-plane translation table; and the three things that genuinely differ (the distro's docker
# rather than a store one, `/etc/docker/daemon.json` written directly rather than through
# `virtualisation.docker`, and the daemon pulled in by a target that Requires= a unit this config
# does not own) each land exactly where the backend's own header says they do.
#
# `makeSystemConfig` gates its entire return value on `config.assertions` passing (its own
# `returnIfNoAssertions`, called unconditionally while building `toplevel`) -- unlike NixOS's
# `eval-config.nix`, `.config` is unreachable when any assertion fails and the whole call throws.
# That is a faithful match for reality (a real host's own build throws identically), so the
# deliberately-failing fixture below is checked with `tryEval` confirming the throw, not by reading
# an assertions list after the fact.
{ pkgs, systemManagerModule, systemManagerLib }:

let
  lib = pkgs.lib;

  digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";

  evalFor = extraConfig:
    (systemManagerLib.makeSystemConfig {
      modules = [
        systemManagerModule
        extraConfig
        { nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system; }
      ];
    }).config;

  evalFails = extraConfig: !(builtins.tryEval (builtins.seq (evalFor extraConfig).systemd.services true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # A host on this plane says exactly what a NixOS host says. That is the whole point: this fixture
  # is copy-pasteable into checks/default.nix's NixOS eval and vice versa.
  workstation = {
    nixdocker.daemon = {
      enable = true;
      firewallBackend = "nftables";
    };
    nixdocker.networks.backend = { subnet = "172.28.0.0/16"; };
    nixdocker.containers.web = {
      image = { repository = "docker.io/library/nginx"; tag = "1.27"; inherit digest; };
      ports = [ "127.0.0.1:8080:80" ];
      networks = [ "backend" ];
      health.cmd = "curl -f http://localhost/health";
    };
  };

  # Docker declared, nothing running: the default state this repo was scoped to produce.
  declaredOnly = {
    nixdocker.daemon = {
      firewallBackend = "nftables";
    };
  };

  containerWithoutDaemon = {
    nixdocker.containers.web.image = {
      repository = "docker.io/library/nginx";
      inherit digest;
    };
  };

  live = evalFor workstation;
  idle = evalFor declaredOnly;

  # The same host, asking for the daemon on demand instead of resident. `onBoot` is the one daemon
  # option this plane expresses by choosing WHICH distro unit to depend on rather than by setting
  # anything, so it needs its own fixture to be provable in both directions -- see below.
  onDemand = evalFor {
    nixdocker.daemon = {
      enable = true;
      onBoot = false;
    };
  };

  results = [
    (check "system-manager/plain-container-becomes-a-real-service"
      (live.systemd.services ? web)
      "expected a declared container to produce systemd.services.web; got: ${builtins.toJSON (lib.attrNames live.systemd.services)}")

    # The generated ExecStart must name the DISTRO's docker, not a nix-built second copy sharing one
    # /var/lib/docker with it.
    (check "system-manager/docker-path-defaults-to-the-distro-binary"
      (live.nixdocker.docker.path == "/usr/bin/docker")
      "nixdocker.docker.path: ${builtins.toJSON live.nixdocker.docker.path}")

    (check "system-manager/the-unit-really-invokes-that-path"
      (lib.hasPrefix ''"/usr/bin/docker" "run"'' live.systemd.services.web.serviceConfig.ExecStart)
      "ExecStart: ${live.systemd.services.web.serviceConfig.ExecStart}")

    (check "system-manager/no-store-docker-survives-into-the-unit"
      (!(lib.hasInfix "${builtins.storeDir}/" live.systemd.services.web.serviceConfig.ExecStart))
      "ExecStart: ${live.systemd.services.web.serviceConfig.ExecStart}")

    # ...and because no build can prove a path outside the store exists, the plane's earliest honest
    # check is registered instead of skipped.
    (check "system-manager/pre-activation-assertion-guards-that-path"
      (
        let a = live.system-manager.preActivationAssertions.nixdocker-docker;
        in a.enable && lib.hasInfix "/usr/bin/docker" a.script
      )
      "preActivationAssertions.nixdocker-docker: ${builtins.toJSON live.system-manager.preActivationAssertions.nixdocker-docker}")

    (check "system-manager/enabling-the-daemon-also-asserts-the-distro-actually-has-one"
      (
        let a = live.system-manager.preActivationAssertions.nixdocker-dockerd;
        in a.enable && lib.hasInfix "docker.service" a.script
      )
      "preActivationAssertions.nixdocker-dockerd: ${builtins.toJSON (live.system-manager.preActivationAssertions ? nixdocker-dockerd)}")

    # ── the daemon: pulled in by a unit we own, never by writing one we do not ──────────────
    (check "system-manager/daemon-comes-up-through-a-target-that-requires-it"
      (
        let t = live.systemd.targets.nixdocker-daemon;
        in t.requires == [ "docker.service" ] && t.wantedBy == [ "multi-user.target" ]
      )
      "systemd.targets.nixdocker-daemon: ${builtins.toJSON live.systemd.targets.nixdocker-daemon}")

    # ── onBoot, BOTH DIRECTIONS ────────────────────────────────────────────────────────────
    # This option was declared for both planes in modules/daemon.nix, consumed only by
    # modules/nixos.nix (`enableOnBoot`), and read by nothing on this plane -- so `onBoot = false`
    # was accepted and silently ignored here while the target pulled docker.service up resident
    # anyway, on the plane this repo's own README calls the PRIMARY one. The check above proves the
    # `true` direction; without this one the `false` direction can regress back to a no-op without
    # anything failing, which is exactly how it went unnoticed the first time.
    (check "system-manager/onBoot-false-requires-the-socket-not-the-service"
      (
        let t = onDemand.systemd.targets.nixdocker-daemon;
        in t.requires == [ "docker.socket" ] && t.after == [ "docker.socket" ]
      )
      "onBoot=false target: ${builtins.toJSON onDemand.systemd.targets.nixdocker-daemon}")

    (check "system-manager/onBoot-false-asserts-against-the-socket-it-actually-depends-on"
      (lib.hasInfix "docker.socket" onDemand.system-manager.preActivationAssertions.nixdocker-dockerd.script)
      "onBoot=false pre-activation assertion did not name docker.socket: ${onDemand.system-manager.preActivationAssertions.nixdocker-dockerd.script}")

    (check "system-manager/this-config-never-defines-docker.service-itself"
      (!(live.systemd.services ? docker))
      "systemd.services would have replaced the distro's own unit file, not dropped into it: ${builtins.toJSON (lib.attrNames live.systemd.services)}")

    # ── daemon.json: written here, because nothing else on this plane owns it ───────────────
    (check "system-manager/daemon-json-is-written-directly"
      (
        let f = live.environment.etc."docker/daemon.json";
        in lib.hasInfix ''"firewall-backend":"nftables"'' f.text && f.mode == "0644"
      )
      "environment.etc.\"docker/daemon.json\": ${builtins.toJSON live.environment.etc."docker/daemon.json".text}")

    # THE SCOPED DEFAULT, PROVEN: config in place, no daemon asked for, no units.
    # `systemd.services` is NOT empty on this plane even for a host that declares nothing --
    # system-manager itself always defines suid-sgid-wrappers, system-manager-path and userborn.
    # So the honest assertion is that nixdocker contributed none of them, which is exactly what
    # `nixdocker.build.services` says.
    (check "system-manager/declared-only-writes-config-and-starts-nothing"
      (
        idle.environment.etc ? "docker/daemon.json"
        && !(idle.systemd.targets ? nixdocker-daemon)
        && idle.nixdocker.build.services == { }
        && !idle.nixdocker.build.anythingDeclared
      )
      "targets: ${builtins.toJSON (lib.attrNames idle.systemd.targets)}, nixdocker services: ${builtins.toJSON (lib.attrNames idle.nixdocker.build.services)}")

    (check "system-manager/a-container-with-the-daemon-off-is-refused-by-name"
      (evalFails containerWithoutDaemon)
      "expected a container declared while nixdocker.daemon.enable is false to fail evaluation on this plane too")

    # ── the network dependency, on the plane it is live on ──────────────────────────────────
    (check "system-manager/network-unit-is-created-and-depended-on"
      (
        (live.systemd.services ? backend-network)
        && lib.elem "backend-network.service" live.systemd.services.web.requires
      )
      "web.requires: ${builtins.toJSON live.systemd.services.web.requires}")

    (check "system-manager/health-flags-survive-systemd-escaping-as-one-argument"
      (lib.hasInfix ''"--health-cmd=curl -f http://localhost/health"'' live.systemd.services.web.serviceConfig.ExecStart)
      "ExecStart: ${live.systemd.services.web.serviceConfig.ExecStart}")
  ];

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then
  throw ''
    nixdocker system-manager eval tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
    ${report}
  ''
else
# Not just an eval: BUILD the /etc tree this plane's config produced, and read the generated unit
# back off disk. This is the end-to-end proof for the plane that actually gets deployed -- the same
# declaration, evaluated through system-manager's own module system rather than NixOS's, still
# produces a unit that calls the distro's docker, and still lands the daemon.json next to it.
  pkgs.runCommand "nixdocker-system-manager-eval-tests"
  {
    etc = live.environment.etc."systemd/system".source;
    daemonJson = pkgs.writeText "daemon.json" live.environment.etc."docker/daemon.json".text;
    passedCount = toString (builtins.length results);
  }
    ''
      set -eu
      SVC=$(readlink -f "$etc/web.service")
      NET=$(readlink -f "$etc/backend-network.service")

      test -e "$SVC" || { echo "the system-manager plane did not produce web.service" >&2; ls -R "$etc" >&2; exit 1; }
      test -e "$NET" || { echo "the system-manager plane did not produce backend-network.service" >&2; ls -R "$etc" >&2; exit 1; }

      grep -q '^ExecStart="/usr/bin/docker" "run"' "$SVC" || { echo "the unit generated on the system-manager plane does not call the distro's docker" >&2; cat "$SVC" >&2; exit 1; }
      grep -q -- '"--publish=127.0.0.1:8080:80"' "$SVC" || { echo "the published port did not reach the unit" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '^Requires=.*docker.socket' "$SVC" || { echo "the unit does not require docker.socket, so a socket-activated daemon would never come up for it" >&2; cat "$SVC" >&2; exit 1; }

      # system-manager rewrites multi-user.target to its own target when it emits the .wants
      # symlink -- so this is where an "enabled" unit actually lands on this plane.
      test -L "$etc/system-manager.target.wants/web.service" || { echo "web.service was not wanted by system-manager.target" >&2; ls -R "$etc" >&2; exit 1; }
      test -L "$etc/system-manager.target.wants/nixdocker-daemon.target" || { echo "the daemon target was not wanted by system-manager.target" >&2; ls -R "$etc" >&2; exit 1; }

      # The distro's own docker.service must be untouched: nothing of that name may be in the tree
      # this config installs.
      if [ -e "$etc/docker.service" ]; then
        echo "this config installed a docker.service of its own, which would shadow the distro's" >&2
        ls -l "$etc/docker.service" >&2
        exit 1
      fi

      grep -q 'firewall-backend' "$daemonJson" || { echo "daemon.json lost the firewall backend" >&2; cat "$daemonJson" >&2; exit 1; }

      echo "all $passedCount nixdocker system-manager eval tests passed, and web.service + backend-network.service were read back out of the real /etc/systemd/system tree this plane builds" > $out
    ''
