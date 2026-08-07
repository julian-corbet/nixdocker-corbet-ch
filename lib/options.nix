# lib/options.nix
#
# Option fragments shared by the two object kinds this repo models (modules/containers.nix,
# modules/networks.nix). Kept here, once, rather than retyped twice, for the same reason nixfs
# keeps its catalogue in `lib/`: these are data about the option SURFACE, cheap to read without a
# module-system evaluation.
#
# WHY THESE LOOK LIKE nixpods' OWN FRAGMENTS, AND WHY THAT IS DELIBERATE. `nixpods` (the podman
# sibling of this repo) carries a `lib/options.nix` with an image-pinning submodule and a
# restart/backoff submodule that read almost the same. That is a chosen parallel, not a missed
# abstraction, and the README's "Why this is not a nixpods backend" section argues it in full. The
# short version: everything else in the two repos is genuinely different -- podman's whole
# mechanism is a build-time run of its own quadlet generator, which docker does not ship and this
# repo therefore cannot use -- and the ~90 lines that ARE common are option fragments whose prose
# has to be written in each engine's own vocabulary anyway. Coupling two leaf repos' `flake.lock`s
# for ninety lines is the more expensive of the two mistakes.
#
# WHAT IS NOT HERE, ON PURPOSE: nixpods' `rootlessOption`. Rootless podman is a per-object
# property -- podman is daemonless, so a uid simply runs its own containers under its own
# `--user` manager. Rootless DOCKER is a whole second daemon per user (`dockerd-rootless.sh` under
# rootlesskit, its own socket, its own storage root), which is a property of a HOST, not of a
# container. Copying a per-object `rootless.uid` here would have modelled something docker does
# not have. See the README's "Rootless" section for what this repo says about it instead.
{ lib }:

rec {
  # THE IMAGE-PINNING SUBMODULE -- the thesis this repo shares with its podman sibling, and the
  # one place the two really are answering the same question about the same registries.
  #
  # `defaults` supplies a default for `repository`/`tag` where a caller genuinely knows the answer;
  # `{ }` leaves `repository` mandatory, which is what a generic container wants. A digest is NEVER
  # defaulted: the digest is the one field whose value is a fact about a moment in time.
  imageOption = defaults: lib.mkOption {
    description = "Which image this container runs, and how it is pinned -- see the submodule's own option docs.";
    type = lib.types.submodule {
      options = {
        repository = lib.mkOption ({
          type = lib.types.str;
          example = "docker.io/library/nginx";
          description = ''
            THE QUESTION: which image repository does this container run? No default unless a
            caller supplied one -- guessing a repository here would be exactly the kind of silent
            drift-by-typo this repo exists to catch, not commit.
          '';
        } // lib.optionalAttrs (defaults ? repository) { default = defaults.repository; });

        tag = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = defaults.tag or null;
          example = "1.27.3";
          description = ''
            A human-readable tag, kept purely for changelog/diff legibility and for tools
            (Renovate and similar) that track upstream releases by tag. NEVER authoritative on its
            own -- `digest` below is what actually resolves the pull; a tag with no digest is
            exactly the floating reference this repo exists to catch (see `allowFloatingTag`).
          '';
        };

        digest = lib.mkOption {
          type = lib.types.nullOr (lib.types.strMatching "sha256:[0-9a-f]{64}");
          default = null;
          example = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
          description = ''
            THE QUESTION THIS OPTION ANSWERS: which exact bytes does this container run,
            regardless of what the registry serves under `tag` tomorrow? Without a digest, the
            docker daemon resolves `tag` at PULL time, so the exact image running on a host is
            whatever the registry currently happens to serve under that name: drift that is, from
            this Nix config's own perspective, indistinguishable from "nothing changed". NO
            DEFAULT. See `allowFloatingTag` for the one deliberate opt-out, and
            modules/containers.nix's own assertion for what happens if neither is set.

            A digest also makes `--pull missing` (this repo's default `pull` policy) exactly
            correct rather than merely convenient: a digest cannot move, so "already present"
            and "what the config asked for" are the same statement.
          '';
        };

        allowFloatingTag = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Explicit acknowledgement: run this container from `tag` alone, with no digest,
            accepting that the registry can move the bits under this host with no corresponding
            change to this Nix config. Default `false` on purpose. Setting this `true` is reported
            in `warnings` by container name every build, so a host that took this shortcut is
            never quietly indistinguishable from one that pinned properly.
          '';
        };
      };
    };
  };

  # Which systemd targets pull this unit in. Left generic rather than derived from anything else,
  # because a network that is only ever reached through a container's own `networks` reference has
  # no reason to also be wanted by a target directly -- modules/nixdocker.nix wires that dependency
  # for real (`Requires=`/`After=` on the network's own unit), so `[ ]` is the honest default
  # there, while a container -- the kind meant to run on its own -- defaults to actually being
  # wanted.
  wantedByOption = default: lib.mkOption {
    type = lib.types.listOf lib.types.str;
    inherit default;
    description = ''
      Which systemd targets this unit is wanted by.

      NOTE ON THE system-manager PLANE: system-manager rewrites `multi-user.target` and
      `timers.target` to its own `system-manager.target` when it emits the `.wants` symlink (read
      out of its `nix/modules/systemd.nix`'s `substituteTarget`, not assumed). So the default here
      is correct on both planes and lands in a different `.wants` directory on each; see
      docs/gotchas.md.
    '';
  };

  # WHAT A DEPLOY DOES TO A UNIT WHOSE DEFINITION CHANGED -- a different question from
  # `restart.policy`, which is what the SUPERVISOR does when the thing it supervises exits. Both
  # activation tools this repo targets read the same key out of the unit's own `[Service]`
  # section: NixOS's switch-to-configuration-ng
  # (`parse_systemd_bool(new_unit_info, "Service", "X-RestartIfChanged", true)`) and
  # system-manager's activator (identical call, identical section).
  #
  # THE FAILURE THIS EXISTS TO PREVENT is on the system-manager plane specifically. Its activator
  # calls `ReloadOrRestartUnit` on every unit whose store path changed, without first checking
  # whether that unit is running -- and `reload-or-restart` STARTS an inactive unit. For an
  # on-demand unit (`wantedBy = [ ]`, started by hand) that turns "I edited an unrelated option
  # and redeployed" into "the job ran".
  restartIfChangedOption = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Whether an activation (`nixos-rebuild switch` / `system-manager switch`) may restart this
      unit when its definition changed.

      Leave `true` for a long-running service: a changed definition should take effect. Set
      `false` for a unit that is started on demand and does real work when it starts.
    '';
  };

  # systemd's own `Restart=` vocabulary, not docker's. The distinction is MORE load-bearing here
  # than it is for podman, not less: `unless-stopped` and `always` are real `docker run --restart`
  # policy names (the string `unless-stopped` is in the docker CLI binary itself), so this is the
  # exact spelling somebody reaching for a restart policy on a docker container is most likely to
  # type -- and systemd does not reject an unknown value. It logs `Failed to parse
  # Restart=unless-stopped, ignoring: Invalid argument` and falls back to `Restart=no`, so a unit
  # asking to be kept alive would quietly never be restarted. The Nix type is the only place that
  # check can happen at all.
  restartPolicies = [ "no" "on-success" "on-failure" "on-abnormal" "on-abort" "on-watchdog" "always" ];

  # systemd refuses to LOAD a `Type=oneshot` unit whose `Restart=` is `always` or `on-success`
  # ("Service has Restart= set to either always or on-success, which isn't allowed for
  # Type=oneshot services. Refusing.") -- a systemd fact, engine-independent, verified against
  # `systemd-analyze verify` for all seven policies (see docs/gotchas.md). That failure lands at
  # unit-load time on the host; modules/containers.nix asserts against this list instead.
  oneshotRestartPolicies = [ "no" "on-failure" "on-abnormal" "on-abort" "on-watchdog" ];

  restartOption = lib.mkOption {
    type = lib.types.submodule {
      options = {
        policy = lib.mkOption {
          type = lib.types.enum restartPolicies;
          default = "on-failure";
          description = ''
            systemd's own `Restart=` policy for the generated service. `on-failure` (the default)
            restarts on a non-zero exit or a signal/timeout/watchdog death, but not on a clean
            exit.

            THIS IS SYSTEMD'S SUPERVISION, AND IT IS THE ONLY SUPERVISION THIS REPO USES. There is
            deliberately no way to set `docker run --restart` from these options, and
            modules/containers.nix asserts that `extraArgs` does not smuggle one in: the daemon's
            own restart policy and systemd's are two supervisors for one container, and they do
            not coordinate. See that assertion's own message, and the README's "One supervisor"
            section.
          '';
        };
        restartSec = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 5;
          description = "Seconds systemd waits before each restart attempt (`RestartSec=`).";
        };
        startLimitBurst = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 3;
          description = ''
            How many restarts within `startLimitIntervalSec` before systemd gives up and leaves
            the unit failed (`StartLimitBurst=`, a `[Unit]`-section key -- yes, distinct from the
            `[Service]`-section `Restart=` above; systemd's own split, not this repo's).
          '';
        };
        startLimitIntervalSec = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 600;
          description = "The rolling window `startLimitBurst` counts restarts over (`StartLimitIntervalSec=`).";
        };
      };
    };
    default = { };
    description = "Restart/backoff convention for this unit -- see the submodule's own option docs.";
  };
}
