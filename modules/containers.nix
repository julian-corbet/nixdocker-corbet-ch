# modules/containers.nix
#
# `nixdocker.containers.<name>` -- the main policy-bearing surface of this repo. Every option here
# renders to a real `docker run` argument via lib/render.nix; nothing in this file talks to docker
# or systemd directly -- see modules/nixdocker.nix for where the rendered argv actually becomes a
# systemd unit.
{ lib, config, ... }:

let
  render = import ../lib/render.nix { inherit lib; };
  opts = import ../lib/options.nix { inherit lib; };

  cfg = config.nixdocker.containers;

  # docker's three built-in networks, which exist without anyone declaring them. Referencing one
  # of these is not a dangling reference; referencing anything else that no `nixdocker.networks`
  # entry defines is.
  builtinNetworks = [ "bridge" "host" "none" ];

  # `docker run --restart=<policy>` hands supervision to the DAEMON. This module never emits one,
  # and this is the list of spellings that would smuggle one in through `extraArgs`. Matched as a
  # prefix because both `--restart=always` and a bare `--restart` (with the value as the next
  # argument) are real command lines.
  restartFlagPrefixes = [ "--restart" ];

  hasRestartFlag = args: lib.any (a: lib.any (p: lib.hasPrefix p a) restartFlagPrefixes) args;

  containerType = lib.types.submodule ({ name, config, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this container's unit is generated and installed at all.";
      };

      # ── image pinning: see the repo README's "image pinning" section for the full case ────
      image = opts.imageOption { };

      pull = lib.mkOption {
        type = lib.types.enum [ "missing" "always" "never" ];
        default = "missing";
        description = ''
          `docker run --pull` policy. `missing` (the default) pulls only when the image is not
          already present locally -- which, for a digest-pinned image, is exactly right rather
          than merely convenient: a digest cannot move, so "already present" and "what the config
          asked for" are the same statement.

          `always` re-resolves on every single start, which for a floating tag means the running
          bits can change without any commit -- the drift this repo exists to prevent. `never`
          refuses to pull at all, for a host whose images arrive some other way (`docker load`).

          The three values are docker's own and it validates them: an unrecognised one is rejected
          with `invalid pull option: '<x>': must be one of "always", "missing" or "never"`.
        '';
      };

      command = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--config" "/etc/example/example.toml" ];
        description = ''
          Arguments appended AFTER the image reference -- the container's own command, replacing
          the image's `CMD` (but not its `ENTRYPOINT`; use `entrypoint` for that). A list, not a
          string, because these become argv entries directly: no shell splits them, so a value
          containing a space stays one argument.

          `[ ]` (the default) runs the image exactly as it defines itself.
        '';
      };

      entrypoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override the image's own ENTRYPOINT (`--entrypoint`). Rarely needed; prefer `command` when the image's own entrypoint is fine as-is.";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "65534:65534";
        description = ''
          Which user (name, or numeric `uid[:gid]`) the process runs as INSIDE the container
          (`--user`). This is the only user-related knob this repo has, and it is not the rootless
          question: rootless docker is a second daemon per user, not a per-container flag -- see
          the README's "Rootless" section.
        '';
      };

      workdir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Working directory inside the container (`--workdir`). `null` leaves the image's own.";
      };

      hostname = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The container's own hostname (`--hostname`). `null` leaves docker's default (the short container id).";
      };

      networks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "backend" ];
        description = ''
          Networks this container joins (`--network`, one flag each). Each entry must either name a
          `nixdocker.networks.<name>` declared alongside this container -- in which case
          modules/nixdocker.nix wires a real `Requires=`/`After=` onto that network's own unit, so
          it is created before this container starts -- or be one of docker's three built-ins
          (`bridge`, `host`, `none`), which always exist. Anything else is a dangling reference and
          fails evaluation by name.

          `[ ]` (the default) leaves docker's own default (the `bridge` network) in place without
          saying so.
        '';
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment variables set inside the container (`--env`, one flag per entry).";
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/run/secrets/example.env" ];
        description = ''
          Files read for further environment variables (`--env-file`, repeatable). Deliberately
          `str` rather than `path`: the point of this option is a file that is NOT in the Nix
          store -- a secret delivered out of band -- and a `path` would copy it into the store,
          which is world-readable.
        '';
      };

      volumes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/srv/example/data:/data" ];
        description = ''
          Raw `SRC:DEST[:OPTIONS]` bind/volume specs (`--volume`, repeatable). `SRC` may be an
          absolute host path or a docker named volume.

          There is no `nixdocker.volumes` module and that is deliberate, not missing: docker
          creates a named volume on first reference, so a module for it would render a unit whose
          only job is something the engine already does. Compare `nixdocker.networks`, which
          exists precisely because docker does NOT auto-create those.
        '';
      };

      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/dev/dri:/dev/dri" ];
        description = ''
          Host device nodes passed into the container as `HOST[:CONTAINER][:PERMISSIONS]`
          (`--device`, repeatable).

          Typed rather than left to `extraArgs` because a hardware dependency is one of the two
          things that make a workload single-host BY NATURE -- which is this repo's own stated
          reason to exist next to k3s. The option a hardware-bound container needs most should not
          be the escape hatch.
        '';
      };

      ports = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "127.0.0.1:8080:80" ];
        description = ''
          Raw `[HOST_IP:]HOSTPORT:CONTAINERPORT` publish specs (`--publish`, repeatable).

          WORTH KNOWING BEFORE USING THIS: publishing a port is what makes the docker daemon
          program the host firewall, and docker's published ports bypass a host's own INPUT rules
          by design (its rules live in the FORWARD/nat path, not INPUT). Binding to an explicit
          host address -- `127.0.0.1:8080:80` rather than `8080:80` -- is the difference between a
          port reachable from localhost and one reachable from the LAN. See docs/gotchas.md and
          `nixdocker.daemon.firewallBackend`.
        '';
      };

      labels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Labels set on the container (`--label`, one flag per entry).";
      };

      capabilities = lib.mkOption {
        description = "Linux capabilities added to or dropped from this container -- see the submodule's own option docs.";
        default = { };
        type = lib.types.submodule {
          options = {
            add = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "NET_ADMIN" ];
              description = "Capabilities granted beyond docker's own default set (`--cap-add`).";
            };
            drop = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "ALL" ];
              description = "Capabilities removed from docker's own default set (`--cap-drop`).";
            };
          };
        };
      };

      privileged = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run the container privileged (`--privileged`) -- effectively all capabilities, all
          devices, and no seccomp/apparmor confinement. `false` on purpose: `capabilities.add` and
          `devices` are the narrow answers to almost every reason somebody reaches for this, and a
          container that genuinely needs raw ioctls should say so here rather than acquire it by
          accumulation.
        '';
      };

      logDriver = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "journald";
        example = "json-file";
        description = ''
          `--log-driver` for this container. Defaults to `journald` -- stated rather than left
          implicit, because docker's own daemon-wide default is `json-file`, which writes to
          `/var/lib/docker/containers/<id>/*.log` and is invisible to `journalctl`. A unit that
          systemd supervises should have logs where a host's other logs are.

          `null` says nothing and leaves whatever `/etc/docker/daemon.json` decided.
        '';
      };

      autoRemove = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Pass `--rm`, so the container is removed when it exits rather than accumulating stopped
          copies. Default `true` because these units always recreate the container from this
          config on every start -- there is no state in a stopped container that this repo would
          ever read back. The generated unit also carries an `ExecStartPre` that force-removes a
          leftover of the same name, for the case where the host died before docker could clean
          up.
        '';
      };

      stopTimeout = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 10;
        description = ''
          Seconds `docker stop` gives the container's main process to exit on SIGTERM before
          sending SIGKILL (`--time`, docker's own default). The generated unit's own
          `TimeoutStopSec=` is set above this so that systemd does not give up on the stop while
          docker is still waiting out this grace period.
        '';
      };

      waitForNetworkOnline = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether the generated unit is ordered after `network-online.target`. Default `true`,
          which matters for a container whose image still has to be pulled on first start.

          Turn this off for a container known to start fine before the network is up:
          `network-online.target` is satisfied by whatever the host's network manager reports, and
          on a laptop that can be a genuinely long wait for something a local container did not
          need.
        '';
      };

      health = lib.mkOption {
        description = "Liveness-check convention for this container -- see the submodule's own option docs.";
        default = { };
        type = lib.types.submodule {
          options = {
            cmd = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "curl -f http://localhost/health";
              description = ''
                THE QUESTION: what command, run inside the container, proves it is actually alive
                -- not merely that its PID exists (`--health-cmd`)? NO DEFAULT: a healthcheck this
                repo invented on a service's behalf would be a fake signal; only the service
                itself knows what liveness means for it. `null` (the default) means no healthcheck
                at all, and every other option in this submodule is then inert -- omitted from the
                argv entirely, not passed with a meaningless value.

                WHAT THIS DOES NOT DO, and the difference from podman is real: docker's
                healthcheck is entirely daemon-side. It sets the container's health status, which
                `docker inspect` and `docker ps` report, and nothing else -- systemd never learns
                about it, because docker has no sd_notify path (podman's `--sdnotify=healthy`
                does). A unit whose container is unhealthy stays `active (running)`. Treat this as
                an observability signal, not as supervision.
              '';
            };
            interval = lib.mkOption {
              type = lib.types.str;
              default = "30s";
              description = "How often the health command re-runs once healthy (`--health-interval`). Inert if `cmd` is unset.";
            };
            timeout = lib.mkOption {
              type = lib.types.str;
              default = "5s";
              description = "How long a single health command run may take before counting as a failure (`--health-timeout`). Inert if `cmd` is unset.";
            };
            retries = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 3;
              description = "Consecutive failures before the container is marked unhealthy (`--health-retries`). Inert if `cmd` is unset.";
            };
            startPeriod = lib.mkOption {
              type = lib.types.str;
              default = "5s";
              description = "Grace period after start during which failures don't count yet (`--health-start-period`). Inert if `cmd` is unset.";
            };
          };
        };
      };

      oneshot = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether this container is a job that RUNS TO COMPLETION rather than a service that stays
          up (`Type=oneshot` in the generated unit instead of systemd's default `Type=simple`).

          NOTE HOW LITTLE THIS CHANGES, compared with the same option on the podman side. `docker
          run` is already a foreground client that exits with the container's own status, so
          `oneshot` here alters nothing about the command -- the argv is byte-identical. What it
          changes is purely systemd's side of the contract: `systemctl start <name>` blocks until
          the job finishes and reports its result, and the unit goes inactive on success instead of
          being considered failed. (nixpods' equivalent option really does change the command
          podman is given, because quadlet drops `-d`/`--sdnotify=conmon` for it; docker never had
          them to drop.)

          Pair this with `wantedBy = [ ]` for a job the operator triggers by hand, and with
          `restartIfChanged = false` so a deploy that changes an unrelated option does not count as
          a trigger.
        '';
      };

      restart = opts.restartOption;

      restartIfChanged = opts.restartIfChangedOption;

      wantedBy = opts.wantedByOption [ "multi-user.target" ];

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--memory=4g" ];
        description = ''
          Extra raw `docker run` flags, inserted after every typed flag above and BEFORE the image
          reference -- so these are always docker's arguments, never the container's. Use
          `command` for the latter.

          Prefer a typed option above whenever the same knob would plausibly get reused; this
          exists for the long tail. One thing it explicitly may not carry: `--restart`. See
          `restart.policy` and this module's own assertion.
        '';
      };

      extraUnitConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = { };
        example = { ConditionPathExists = "/dev/kvm"; };
        description = "Escape hatch into the generated unit's `[Unit]` section for keys not modeled above.";
      };

      extraServiceConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = { };
        example = { MemoryMax = "4G"; };
        description = ''
          Escape hatch into the generated unit's `[Service]` section for keys not modeled above.

          Worth knowing what does NOT work here: systemd resource limits set on this unit
          constrain the `docker run` CLIENT, not the container. The container's processes live in
          the daemon's own cgroup tree, not this unit's. Use docker's own `--memory`/`--cpus` via
          `extraArgs` for that.
        '';
      };

      # ── computed, read-only -- consumed by modules/nixdocker.nix ────────────────────────────
      serviceName = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        description = "The systemd service name (without .service) this container becomes.";
      };
      containerName = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        description = "The name docker itself knows this container by (`--name`).";
      };
    };

    config = {
      serviceName = name;
      containerName = name;
    };
  });
in
{
  options.nixdocker.containers = lib.mkOption {
    type = lib.types.attrsOf containerType;
    default = { };
    description = ''
      Docker containers declared as ordinary systemd service units, each one a foreground
      `docker run` whose full argv is rendered from these typed options -- see the repo README for
      the mechanism, and for what it does and does not guarantee compared with its podman sibling.
    '';
  };

  config = {
    assertions = lib.flatten (lib.mapAttrsToList
      (n: c: [
        {
          assertion = !c.enable || c.image.digest != null || c.image.allowFloatingTag;
          message = ''
            nixdocker.containers.${n}.image: no digest set, and allowFloatingTag is false (its
            default). This container would run from
            "${c.image.repository}${lib.optionalString (c.image.tag != null) ":${c.image.tag}"}"
            alone -- a tag the daemon resolves at PULL time, so the exact bits that land on this
            host are whatever the registry currently serves under that name, indistinguishable
            from Nix's own perspective from "nothing changed". Pin an image digest
            (nixdocker.containers.${n}.image.digest = "sha256:...") or, if this container
            genuinely must float, set nixdocker.containers.${n}.image.allowFloatingTag = true and
            accept the warning that comes with it.
          '';
        }
        {
          assertion = !c.enable || !c.oneshot || lib.elem c.restart.policy opts.oneshotRestartPolicies;
          message = ''
            nixdocker.containers.${n} is oneshot = true with restart.policy = "${c.restart.policy}".
            systemd REFUSES TO LOAD a Type=oneshot unit whose Restart= is "always" or "on-success"
            ("Service has Restart= set to either always or on-success, which isn't allowed for
            Type=oneshot services. Refusing.") -- and it refuses at unit-load time on the host,
            long after any build has succeeded. Use one of:
            ${lib.concatStringsSep ", " opts.oneshotRestartPolicies}. For a job an operator
            triggers by hand, "no" is almost always the honest answer -- a rerun is a decision, not
            a retry.
          '';
        }
        {
          assertion = !c.enable || !(hasRestartFlag c.extraArgs);
          message = ''
            nixdocker.containers.${n}.extraArgs carries a --restart flag. That hands this
            container to a SECOND supervisor: the docker daemon would restart it on its own
            schedule while systemd, which owns this unit, restarts the `docker run` client on
            restart.policy = "${c.restart.policy}". The two do not coordinate, and the visible
            symptom is a container that comes back while its unit reads `inactive`, or two of it.

            The daemon half-catches this already -- it refuses the combination with "can't create
            'AutoRemove' container with restart policy" -- but only while autoRemove is true, which
            is a default, not a guarantee, and the diagnostic arrives at container-start time on
            the host rather than here.

            Use nixdocker.containers.${n}.restart.policy for supervision; it is systemd's
            Restart=, and it is the only supervision this repo installs.
          '';
        }
        {
          assertion = !c.enable || lib.all
            (net: lib.elem net builtinNetworks || (config.nixdocker.networks ? ${net}))
            c.networks;
          message = ''
            nixdocker.containers.${n}.networks references
            ${lib.concatStringsSep ", " (lib.filter (net: !(lib.elem net builtinNetworks) && !(config.nixdocker.networks ? ${net})) c.networks)},
            which is neither declared in nixdocker.networks nor one of docker's own built-ins
            (${lib.concatStringsSep ", " builtinNetworks}). Unlike a named volume, docker does NOT
            create a network on first reference: `docker run --network=<unknown>` fails at start
            time with "network <unknown> not found". Declare nixdocker.networks.<name> alongside
            this container -- which also gets it a real Requires=/After= on that network's own
            unit -- or point `networks` at one that already exists.
          '';
        }
      ])
      cfg);

    warnings = lib.flatten (lib.mapAttrsToList
      (n: c: lib.optional (c.enable && c.image.digest == null && c.image.allowFloatingTag) ''
        nixdocker.containers.${n}: running from an unpinned tag
        ("${c.image.repository}${lib.optionalString (c.image.tag != null) ":${c.image.tag}"}") by
        explicit choice (allowFloatingTag = true). The registry can move these bits under this
        host at any time with no corresponding change in this Nix config -- drift, accepted
        knowingly. Pin `image.digest` to close this warning.
      '')
      cfg);
  };
}
