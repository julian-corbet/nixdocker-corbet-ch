# checks/default.nix
#
# Three kinds of check, cheapest first:
#
#   1. "render/*" -- pure unit tests against lib/render.nix directly. No module-system eval, no
#      derivation, no docker: hand-built plain-value fixtures in, an argv list out, assertions on
#      the individual arguments.
#
#   2. Everything under `results` -- EVAL-TIME tests through real `nixosSystem` composition: does a
#      host importing `modules/nixos.nix` evaluate at all, and -- the failing direction, proven as
#      deliberately as the passing one -- does an unpinned image, a dangling network reference, a
#      `--restart` smuggled through `extraArgs`, a container declared while the daemon is off, or a
#      `Type=oneshot` unit with a `Restart=` systemd would refuse to load each fail evaluation BY
#      NAME rather than silently produce something half-formed.
#
#   3. `renders-a-real-unit-file` -- the one ACTUAL BUILD in this file. It takes the `.service`
#      file NixOS's own systemd machinery produced from these definitions and greps it for the
#      lines that prove the wiring survived the round trip.
#
# WHY THAT THIRD TIER IS THINNER THAN THE PODMAN SIBLING'S, AND HONESTLY SO. nixpods' equivalent
# checks run podman's real quadlet generator inside the build sandbox and grep ITS output, which
# proves a fact about the generator binary that no eval-time check could reach. There is no docker
# generator to run, so the only thing a build can add here is that the unit text this repo composed
# really does come out of systemd's own unit writer intact -- worth checking, and a smaller claim.
# What CANNOT be checked anywhere in this file is whether the rendered `docker run` argv is one the
# docker CLI accepts: that needs a daemon, which needs root and a running host, which is exactly
# what a check may not have. See the README's "What this repo cannot promise".
{ pkgs, lib, system, nixdockerModule, packagesModule }:

let
  render = import ../lib/render.nix { inherit lib; };

  check = name: ok: detail: { inherit name ok detail; };

  digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";

  # ── Stubs every fixture below needs to reach system.build.toplevel ──────────────────
  bootStub = {
    fileSystems."/" = { device = "nodev"; fsType = "tmpfs"; };
    boot.loader.grub = { enable = true; devices = [ "nodev" ]; };
    networking.hostName = "example-docker-host";
    system.stateVersion = "25.05";
  };

  evalNixos = extraConfig:
    (lib.nixosSystem {
      inherit system;
      modules = [ nixdockerModule extraConfig bootStub ];
    }).config;

  # Forcing `system.build.toplevel.drvPath` is what actually runs `assertions` (a bare read of
  # `.config.assertions` is a passive list nobody enforced yet); `seq` reaches the wrapping `throw`
  # without deep-forcing or building the whole system closure, and the string context is discarded
  # so this stays an EVAL check, never a build.
  evalToplevel = extraConfig:
    builtins.tryEval (builtins.seq
      (builtins.unsafeDiscardStringContext (evalNixos extraConfig).system.build.toplevel.drvPath)
      true);

  evalOk = extraConfig: (evalToplevel extraConfig).success;
  buildFails = extraConfig: !(evalToplevel extraConfig).success;

  # ── nixdocker.packages -- a SEPARATE opt-in module (modules/packages.nixos.nix), not pulled in
  # by nixdockerModule, so it needs its own composition rather than reusing evalNixos/evalToplevel
  # above. Same proof nixiam's own checks/default.nix runs for its packages module: the baseline
  # resolves on NixOS, and an unresolvable override fails the build by name.
  evalNixosPackages = extraConfig:
    (lib.nixosSystem {
      inherit system;
      modules = [ packagesModule extraConfig bootStub ];
    }).config;

  packagesEvalToplevel = extraConfig:
    builtins.tryEval (builtins.seq
      (builtins.unsafeDiscardStringContext (evalNixosPackages extraConfig).system.build.toplevel.drvPath)
      true);

  packagesEvalOk = extraConfig: (packagesEvalToplevel extraConfig).success;
  packagesBuildFails = extraConfig: !(packagesEvalToplevel extraConfig).success;

  # ── Fixtures ─────────────────────────────────────────────────────────────────────
  daemonOn = { nixdocker.daemon.enable = true; };

  pinnedContainer = {
    imports = [
      daemonOn
      {
        nixdocker.containers.example = {
          image = { repository = "docker.io/library/nginx"; tag = "1.27"; inherit digest; };
        };
      }
    ];
  };

  unpinnedContainer = {
    imports = [
      daemonOn
      { nixdocker.containers.example.image.repository = "docker.io/library/nginx"; }
    ];
  };

  unpinnedButAcknowledged = {
    imports = [
      daemonOn
      {
        nixdocker.containers.example.image = {
          repository = "docker.io/library/nginx";
          allowFloatingTag = true;
        };
      }
    ];
  };

  badDigestFormat = {
    imports = [
      daemonOn
      {
        nixdocker.containers.example.image = {
          repository = "docker.io/library/nginx";
          digest = "not-a-real-digest";
        };
      }
    ];
  };

  # THE ONE THAT MAKES "OFF BY DEFAULT" REAL: a container with no daemon.enable must not quietly
  # evaluate, because its unit's Requires=docker.socket would bring the daemon up anyway.
  containerWithoutDaemon = {
    nixdocker.containers.example.image = {
      repository = "docker.io/library/nginx";
      inherit digest;
    };
  };

  containerWithMissingNetwork = {
    imports = [
      daemonOn
      {
        nixdocker.containers.example = {
          image = { repository = "docker.io/library/nginx"; inherit digest; };
          networks = [ "does-not-exist" ];
        };
      }
    ];
  };

  containerWithBuiltinNetwork = {
    imports = [
      daemonOn
      {
        nixdocker.containers.example = {
          image = { repository = "docker.io/library/nginx"; inherit digest; };
          networks = [ "host" ];
        };
      }
    ];
  };

  containerWithRealNetwork = {
    imports = [
      daemonOn
      {
        nixdocker.containers.example = {
          image = { repository = "docker.io/library/nginx"; inherit digest; };
          networks = [ "backend" ];
        };
        nixdocker.networks.backend = { subnet = "172.28.0.0/16"; };
      }
    ];
  };

  containerWithSmuggledRestart = {
    imports = [
      daemonOn
      {
        nixdocker.containers.example = {
          image = { repository = "docker.io/library/nginx"; inherit digest; };
          extraArgs = [ "--restart=always" ];
        };
      }
    ];
  };

  oneshotIllegalRestart = {
    imports = [
      daemonOn
      {
        nixdocker.containers.example = {
          image = { repository = "docker.io/library/nginx"; inherit digest; };
          oneshot = true;
          restart.policy = "always";
        };
      }
    ];
  };

  # Deliberately declares the SAME image as `pinnedContainer` above, tag included: the
  # "oneshot changes systemd's contract and not the command" check below compares the two
  # rendered ExecStart lines directly, and any other difference between the fixtures would make
  # that comparison prove nothing.
  oneshotLegalRestart = {
    imports = [
      daemonOn
      {
        nixdocker.containers.example = {
          image = { repository = "docker.io/library/nginx"; tag = "1.27"; inherit digest; };
          oneshot = true;
          restart.policy = "no";
          wantedBy = [ ];
          restartIfChanged = false;
        };
      }
    ];
  };

  daemonWithBothFirewallKeys = {
    nixdocker.daemon = {
      enable = true;
      firewallBackend = "nftables";
      settings."firewall-backend" = "iptables";
    };
  };

  daemonWithNftables = {
    nixdocker.daemon = {
      enable = true;
      firewallBackend = "nftables";
      dataRoot = "/var/lib/docker";
      settings.log-driver = "journald";
    };
  };

  serviceNameCollision = {
    imports = [
      daemonOn
      {
        # The network `backend` takes the service name `backend-network`; a container literally
        # called that collides with it.
        nixdocker.networks.backend = { };
        nixdocker.containers.backend-network.image = {
          repository = "docker.io/library/nginx";
          inherit digest;
        };
      }
    ];
  };

  packagesBaselineMissing = {
    nixdocker.packages.baseline = [ "docker-compose" "docker-buildx" "definitely-does-not-exist-in-nixpkgs" ];
  };

  results = [
    # --- a fully-pinned container composes -------------------------------------------
    (check "pinned-container/toplevel-evaluates"
      (evalOk pinnedContainer)
      "expected a container with repository+tag+digest set, alongside daemon.enable, to evaluate cleanly")

    (check "pinned-container/no-warnings"
      ((evalNixos pinnedContainer).warnings == [ ])
      "warnings: ${builtins.toJSON (evalNixos pinnedContainer).warnings}")

    # --- the repo's thesis, direction one: an unpinned image fails BY NAME -----------
    (check "unpinned-image/fails-evaluation"
      (buildFails unpinnedContainer)
      "expected a container with no digest and allowFloatingTag left false (its default) to fail evaluation, but it succeeded")

    (check "unpinned-image-acknowledged/succeeds-with-named-warning"
      (
        let w = (evalNixos unpinnedButAcknowledged).warnings;
        in evalOk unpinnedButAcknowledged && lib.any (m: lib.hasInfix "nixdocker.containers.example" m) w
      )
      "expected allowFloatingTag = true to evaluate cleanly AND produce a warning naming the container; warnings: ${builtins.toJSON (evalNixos unpinnedButAcknowledged).warnings}")

    (check "bad-digest-format/fails-evaluation"
      (buildFails badDigestFormat)
      "expected digest = \"not-a-real-digest\" (fails the sha256:<64 hex> type) to fail evaluation, but it succeeded")

    # --- "off by default" is enforced, not merely documented -------------------------
    (check "container-without-daemon/fails-evaluation"
      (buildFails containerWithoutDaemon)
      "expected a container declared while nixdocker.daemon.enable is false (its default) to fail evaluation -- its unit's Requires=docker.socket would bring the daemon up regardless, so the config would be saying something untrue about this host")

    (check "daemon-off-by-default/nothing-declared-still-evaluates"
      (evalOk { })
      "expected a host that imports nixdocker and declares nothing at all to evaluate cleanly with no daemon")

    (check "daemon-off/installs-no-docker-on-the-nixos-plane"
      (!(evalNixos { }).virtualisation.docker.enable)
      "virtualisation.docker.enable with nixdocker imported and nothing declared: ${builtins.toJSON (evalNixos { }).virtualisation.docker.enable}")

    (check "daemon-on/turns-the-nixos-docker-module-on"
      (
        let c = evalNixos daemonWithNftables;
        in c.virtualisation.docker.enable && c.virtualisation.docker.enableOnBoot
      )
      "virtualisation.docker: enable=${builtins.toJSON (evalNixos daemonWithNftables).virtualisation.docker.enable}, enableOnBoot=${builtins.toJSON (evalNixos daemonWithNftables).virtualisation.docker.enableOnBoot}")

    # --- the daemon.json document, typed knobs merged into the freeform one ----------
    (check "daemon-settings/typed-knobs-reach-the-real-nixos-option"
      (
        let s = (evalNixos daemonWithNftables).virtualisation.docker.daemon.settings;
        in s."firewall-backend" == "nftables" && s.data-root == "/var/lib/docker" && s.log-driver == "journald"
      )
      "virtualisation.docker.daemon.settings: ${builtins.toJSON (evalNixos daemonWithNftables).virtualisation.docker.daemon.settings}")

    (check "daemon-settings/two-writers-for-one-key-fails-evaluation"
      (buildFails daemonWithBothFirewallKeys)
      "expected firewallBackend and settings.\"firewall-backend\" set together to fail evaluation, but it succeeded")

    # --- network references must resolve, because docker does not auto-create them ---
    (check "container-network-reference/fails-when-network-undeclared"
      (buildFails containerWithMissingNetwork)
      "expected networks = [ \"does-not-exist\" ] with no matching nixdocker.networks entry to fail evaluation, but it succeeded")

    (check "container-network-reference/builtin-networks-need-no-declaration"
      (evalOk containerWithBuiltinNetwork)
      "expected networks = [ \"host\" ] (one of docker's built-ins) to evaluate cleanly with no nixdocker.networks entry")

    (check "container-network-reference/succeeds-and-wires-a-real-dependency"
      (
        let svc = (evalNixos containerWithRealNetwork).systemd.services.example;
        in lib.elem "backend-network.service" svc.requires && lib.elem "backend-network.service" svc.after
      )
      "systemd.services.example: requires=${builtins.toJSON (evalNixos containerWithRealNetwork).systemd.services.example.requires}, after=${builtins.toJSON (evalNixos containerWithRealNetwork).systemd.services.example.after}")

    (check "network/renders-a-remain-after-exit-oneshot"
      (
        let svc = (evalNixos containerWithRealNetwork).systemd.services.backend-network;
        in svc.serviceConfig.Type == "oneshot" && svc.serviceConfig.RemainAfterExit
      )
      "systemd.services.backend-network.serviceConfig: ${builtins.toJSON (evalNixos containerWithRealNetwork).systemd.services.backend-network.serviceConfig}")

    # --- one supervisor: a --restart smuggled through extraArgs is refused -----------
    (check "smuggled-restart-flag/fails-evaluation"
      (buildFails containerWithSmuggledRestart)
      "expected extraArgs = [ \"--restart=always\" ] to fail evaluation -- the daemon's own restart policy and systemd's Restart= are two supervisors for one container")

    # --- oneshot x restart policy: systemd refuses to LOAD the combination -----------
    (check "oneshot-restart-always/fails-evaluation"
      (buildFails oneshotIllegalRestart)
      "expected oneshot = true with restart.policy = \"always\" (a combination systemd refuses to load) to fail evaluation, but it succeeded")

    (check "oneshot-restart-no/succeeds"
      (evalOk oneshotLegalRestart)
      "expected oneshot = true with restart.policy = \"no\" to evaluate cleanly")

    (check "oneshot/reaches-the-real-unit-as-type-oneshot"
      (
        let svc = (evalNixos oneshotLegalRestart).systemd.services.example;
        in svc.serviceConfig.Type == "oneshot" && svc.wantedBy == [ ] && !svc.restartIfChanged
      )
      "systemd.services.example: ${builtins.toJSON (evalNixos oneshotLegalRestart).systemd.services.example.serviceConfig}")

    # --- oneshot changes systemd's contract and NOT the command, unlike the podman side
    (check "oneshot/leaves-the-docker-argv-byte-identical"
      (
        let
          plain = (evalNixos pinnedContainer).systemd.services.example.serviceConfig.ExecStart;
          job = (evalNixos oneshotLegalRestart).systemd.services.example.serviceConfig.ExecStart;
        in
        plain == job
      )
      "plain ExecStart: ${(evalNixos pinnedContainer).systemd.services.example.serviceConfig.ExecStart}\noneshot ExecStart: ${(evalNixos oneshotLegalRestart).systemd.services.example.serviceConfig.ExecStart}")

    # --- generated systemd wiring: the daemon ordering every container gets ----------
    (check "container-unit/is-ordered-against-the-daemon"
      (
        let svc = (evalNixos pinnedContainer).systemd.services.example;
        in lib.elem "docker.socket" svc.requires
          && lib.elem "docker.service" svc.after
          && lib.elem "docker.socket" svc.after
      )
      "systemd.services.example: requires=${builtins.toJSON (evalNixos pinnedContainer).systemd.services.example.requires}, after=${builtins.toJSON (evalNixos pinnedContainer).systemd.services.example.after}")

    (check "container-unit/sweeps-a-leftover-before-and-after"
      (
        let sc = (evalNixos pinnedContainer).systemd.services.example.serviceConfig;
        in lib.hasPrefix "-" sc.ExecStartPre
          && lib.hasInfix "rm" sc.ExecStartPre
          && lib.hasPrefix "-" sc.ExecStopPost
      )
      "serviceConfig: ${builtins.toJSON (evalNixos pinnedContainer).systemd.services.example.serviceConfig}")

    (check "container-unit/stop-timeout-exceeds-the-docker-stop-grace-period"
      (
        let sc = (evalNixos pinnedContainer).systemd.services.example.serviceConfig;
        in sc.TimeoutStopSec > 10 && lib.hasInfix "--time" sc.ExecStop
      )
      "serviceConfig: TimeoutStopSec=${builtins.toJSON (evalNixos pinnedContainer).systemd.services.example.serviceConfig.TimeoutStopSec}, ExecStop=${(evalNixos pinnedContainer).systemd.services.example.serviceConfig.ExecStop}")

    # --- two objects must not resolve to one unit -----------------------------------
    (check "duplicate-service-name/fails-evaluation"
      (buildFails serviceNameCollision)
      "expected a container named \"backend-network\" alongside a network named \"backend\" (which takes that same service name) to fail evaluation, but it succeeded")

    # --- on the NixOS plane the unit names this host's own docker, out of the store --
    (check "nixos-plane/docker-path-is-a-store-path"
      (lib.hasPrefix builtins.storeDir (evalNixos pinnedContainer).nixdocker.docker.path)
      "nixdocker.docker.path: ${(evalNixos pinnedContainer).nixdocker.docker.path}")
  ];

  # ── nixdocker.packages -- the declared host tooling exception, proven the same way nixiam
  # proves its own baseline: resolves cleanly by default, fails by name when it cannot ─────────
  packageResults = [
    (check "packages/default-baseline-builds-on-nixos"
      (packagesEvalOk { })
      "nixdocker packages baseline must resolve on NixOS without failing the build")

    (check "packages/baseline-names-compose-and-buildx"
      ((evalNixosPackages { }).nixdocker.packages.baseline == [ "docker" "docker-compose" "docker-buildx" ])
      "nixdocker.packages.baseline: ${builtins.toJSON (evalNixosPackages { }).nixdocker.packages.baseline}")

    (check "packages/compose-and-buildx-reach-environment-systemPackages"
      (
        let names = map (p: p.pname or p.name) (evalNixosPackages { }).environment.systemPackages;
        in lib.elem "docker-compose" names && lib.elem "docker-buildx" names
      )
      "environment.systemPackages: ${builtins.toJSON (map (p: p.pname or p.name) (evalNixosPackages { }).environment.systemPackages)}")

    (check "packages/unresolvable-entry-fails-on-nixos"
      (packagesBuildFails packagesBaselineMissing)
      "a baseline override that names a non-existent nixpkgs package must fail on NixOS")
  ];

  # ── Pure render-time checks: no nixosSystem at all -------------------------------
  baseContainerCfg = {
    image = { repository = "docker.io/library/nginx"; tag = "1.27"; inherit digest; };
    pull = "missing";
    command = [ ];
    entrypoint = null;
    user = null;
    workdir = null;
    hostname = null;
    networks = [ ];
    environment = { };
    environmentFiles = [ ];
    volumes = [ ];
    devices = [ ];
    ports = [ ];
    labels = { };
    capabilities = { add = [ ]; drop = [ ]; };
    privileged = false;
    logDriver = "journald";
    autoRemove = true;
    health = { cmd = null; interval = "30s"; timeout = "5s"; retries = 3; startPeriod = "5s"; };
    extraArgs = [ ];
  };

  argvFor = overrides: render.mkRunArgv {
    docker = "/usr/bin/docker";
    name = "example";
    cfg = baseContainerCfg // overrides;
  };

  baseNetworkCfg = {
    driver = null;
    subnet = null;
    gateway = null;
    internal = false;
    ipv6 = false;
    extraArgs = [ ];
  };

  renderResults = [
    (check "render/image-ref-includes-tag-and-digest"
      (render.mkImageRef { repository = "example.org/app"; tag = "1.0"; inherit digest; } == "example.org/app:1.0@${digest}")
      "got: ${render.mkImageRef { repository = "example.org/app"; tag = "1.0"; inherit digest; }}")

    (check "render/image-ref-digest-only-omits-tag-colon"
      (render.mkImageRef { repository = "example.org/app"; tag = null; inherit digest; } == "example.org/app@${digest}")
      "got: ${render.mkImageRef { repository = "example.org/app"; tag = null; inherit digest; }}")

    (check "render/argv-starts-with-the-docker-binary-and-run"
      (lib.take 2 (argvFor { }) == [ "/usr/bin/docker" "run" ])
      "argv: ${builtins.toJSON (argvFor { })}")

    (check "render/argv-ends-with-the-image-when-no-command-is-given"
      (lib.last (argvFor { }) == "docker.io/library/nginx:1.27@${digest}")
      "argv: ${builtins.toJSON (argvFor { })}")

    # THE ORDERING FACT THAT MATTERS: everything docker reads after the image name belongs to the
    # container's process, so a flag landing behind it silently becomes an argument to the app.
    (check "render/every-flag-comes-before-the-image-and-the-command-after-it"
      (
        let
          argv = argvFor { extraArgs = [ "--memory=4g" ]; command = [ "--config" "/etc/x.toml" ]; };
          imageIndex = lib.lists.findFirstIndex (a: lib.hasInfix "@sha256:" a) null argv;
          flagIndex = lib.lists.findFirstIndex (a: a == "--memory=4g") null argv;
          cmdIndex = lib.lists.findFirstIndex (a: a == "--config") null argv;
        in
        flagIndex < imageIndex && cmdIndex > imageIndex
      )
      "argv: ${builtins.toJSON (argvFor { extraArgs = [ "--memory=4g" ]; command = [ "--config" "/etc/x.toml" ]; })}")

    (check "render/no-healthcheck-omits-all-health-flags"
      (!(lib.any (a: lib.hasPrefix "--health" a) (argvFor { })))
      "argv: ${builtins.toJSON (argvFor { })}")

    (check "render/healthcheck-set-renders-all-five-flags"
      (
        let argv = argvFor { health = baseContainerCfg.health // { cmd = "curl -f http://localhost/health"; }; };
        in lib.elem "--health-cmd=curl -f http://localhost/health" argv
          && lib.elem "--health-interval=30s" argv
          && lib.elem "--health-timeout=5s" argv
          && lib.elem "--health-retries=3" argv
          && lib.elem "--health-start-period=5s" argv
      )
      "argv: ${builtins.toJSON (argvFor { health = baseContainerCfg.health // { cmd = "curl -f http://localhost/health"; }; })}")

    (check "render/repeatable-flags-render-one-entry-each"
      (
        let argv = argvFor { volumes = [ "/a:/a" "/b:/b" ]; ports = [ "80:80" "443:443" ]; devices = [ "/dev/dri:/dev/dri" ]; };
        in lib.elem "--volume=/a:/a" argv && lib.elem "--volume=/b:/b" argv
          && lib.elem "--publish=80:80" argv && lib.elem "--publish=443:443" argv
          && lib.elem "--device=/dev/dri:/dev/dri" argv
      )
      "argv: ${builtins.toJSON (argvFor { volumes = [ "/a:/a" "/b:/b" ]; ports = [ "80:80" "443:443" ]; devices = [ "/dev/dri:/dev/dri" ]; })}")

    (check "render/journald-log-driver-is-stated-not-assumed"
      (lib.elem "--log-driver=journald" (argvFor { }))
      "argv: ${builtins.toJSON (argvFor { })}")

    (check "render/log-driver-null-says-nothing"
      (!(lib.any (a: lib.hasPrefix "--log-driver" a) (argvFor { logDriver = null; })))
      "argv: ${builtins.toJSON (argvFor { logDriver = null; })}")

    # systemd's ExecStart is not a shell: a value with a space must survive as ONE argument, and a
    # `%` must not be read as a specifier.
    (check "render/systemd-escaping-keeps-a-spaced-value-one-argument"
      (render.escapeSystemdExecArgs [ "--health-cmd=curl -f http://x/y" ] == ''"--health-cmd=curl -f http://x/y"'')
      "got: ${render.escapeSystemdExecArgs [ "--health-cmd=curl -f http://x/y" ]}")

    (check "render/systemd-escaping-neutralises-specifiers-and-variables"
      (render.escapeSystemdExecArgs [ "a%n" "b$HOME" ] == ''"a%%n" "b$$HOME"'')
      "got: ${render.escapeSystemdExecArgs [ "a%n" "b$HOME" ]}")

    (check "render/network-script-is-create-if-absent-and-says-so"
      (
        let text = render.mkNetworkScript { docker = "/usr/bin/docker"; name = "backend"; cfg = baseNetworkCfg // { subnet = "172.28.0.0/16"; }; };
        in lib.hasInfix "network inspect" text
          && lib.hasInfix "network create" text
          && lib.hasInfix "--subnet=172.28.0.0/16" text
          && lib.hasInfix "no reconcile verb" text
      )
      "script: ${render.mkNetworkScript { docker = "/usr/bin/docker"; name = "backend"; cfg = baseNetworkCfg // { subnet = "172.28.0.0/16"; }; }}")
  ];

  allResults = results ++ renderResults ++ packageResults;
  failed = builtins.filter (r: !r.ok) allResults;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  # ── The one REAL build in this check suite ------------------------------------------------
  # `systemd.units.<name>.unit` is the derivation NixOS's own unit writer produced from the
  # definitions this repo composed. Building it and grepping the file is the end of the round trip:
  # it proves the escaped ExecStart, the daemon ordering and the sweeps are really in the unit that
  # would land on a host, not merely in an attrset that looked right at eval time.
  realUnitCheck = pkgs.runCommand "nixdocker-renders-a-real-unit-file"
    {
      unit = (evalNixos containerWithRealNetwork).systemd.units."example.service".unit;
      networkUnit = (evalNixos containerWithRealNetwork).systemd.units."backend-network.service".unit;
    }
    ''
      set -eu
      SVC="$unit/example.service"
      NET="$networkUnit/backend-network.service"

      test -e "$SVC" || { echo "expected example.service to exist, it does not" >&2; ls -R "$unit" >&2; exit 1; }
      test -e "$NET" || { echo "expected backend-network.service to exist, it does not" >&2; ls -R "$networkUnit" >&2; exit 1; }

      grep -q '^ExecStart=.*/bin/docker" "run"' "$SVC" || { echo "example.service has no real docker run ExecStart=" >&2; cat "$SVC" >&2; exit 1; }
      grep -q -- '"--rm"' "$SVC" || { echo "example.service lost --rm" >&2; cat "$SVC" >&2; exit 1; }
      grep -q -- '"--network=backend"' "$SVC" || { echo "example.service lost its --network" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '@sha256:' "$SVC" || { echo "example.service does not name a digest-pinned image" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '^Requires=.*docker.socket' "$SVC" || { echo "example.service does not require docker.socket" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '^Requires=.*backend-network.service' "$SVC" || { echo "example.service does not require its network's unit" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '^ExecStartPre=-' "$SVC" || { echo "example.service has no failure-tolerated ExecStartPre sweep" >&2; cat "$SVC" >&2; exit 1; }

      # The daemon's own restart policy must not be anywhere near this unit -- systemd's Restart= is
      # the only supervision this repo installs.
      if grep -q -- '"--restart' "$SVC"; then
        echo "a docker --restart flag reached the generated unit -- that is a second supervisor" >&2
        cat "$SVC" >&2
        exit 1
      fi

      grep -q '^Type=oneshot$' "$NET" || { echo "the network unit is not a oneshot" >&2; cat "$NET" >&2; exit 1; }
      grep -q '^RemainAfterExit=true$' "$NET" || { echo "the network unit does not remain after exit, so a container's Requires= on it would not stay satisfied" >&2; cat "$NET" >&2; exit 1; }

      echo "the composed definitions round-tripped through systemd's own unit writer with the docker argv, the daemon ordering, the network dependency and the sweeps intact" > $out
    '';
in
if failed != [ ]
then
  throw ''
    nixdocker eval/render tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length allResults)}):
    ${report}
  ''
else {
  eval-tests = pkgs.runCommand "nixdocker-eval-tests"
    { passedCount = toString (builtins.length allResults); }
    ''
      echo "all $passedCount nixdocker eval/render tests passed"
      touch $out
    '';

  renders-a-real-unit-file = realUnitCheck;
}
