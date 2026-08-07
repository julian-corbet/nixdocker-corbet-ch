# lib/render.nix
#
# Pure rendering: a resolved container/network option value (every option already at its final
# value -- this file never sees an unset option) -> the `docker` argv that runs it, and the shell
# text a network's own unit executes. No `config`, no module system, no derivations -- which is
# what lets checks/default.nix hit these functions directly with hand-built fixtures, and lets
# modules/*.nix stay thin.
#
# WHAT THIS FILE IS NOT, AND WHY THAT IS THE WHOLE DIFFERENCE FROM ITS PODMAN SIBLING. nixpods'
# lib/render.nix renders Quadlet INI text, which podman's own `quadlet` binary -- a real systemd
# generator, shipped in the podman package -- then translates into a `.service` file. nixpods runs
# that generator inside the Nix build sandbox, which is that repo's entire thesis: a malformed
# input fails the BUILD, because a real translator looked at it.
#
# DOCKER SHIPS NO SUCH BINARY. There is no docker quadlet, no `docker-system-generator`, nothing
# in the docker package under `lib/systemd/system-generators/`. A docker container under systemd
# is a unit whose `ExecStart=` is a foreground `docker run` client; the container itself is a
# child of `dockerd`, not of systemd. So there is no generator to run early, and this file writes
# the unit's command line itself.
#
# That is a genuinely weaker guarantee than nixpods', and this repo says so out loud rather than
# implying otherwise (see the README's "What this repo cannot promise"). What it does buy: the
# argv is an ordinary Nix value, visible at eval time, so checks/ can assert against the exact
# flags without building anything -- which nixpods cannot do, because its flags only exist once
# the generator has run.
{ lib }:

let
  # VENDORED, NOT DEPENDED ON: nixpkgs' own `escapeSystemdExecArg` from `nixos/lib/utils.nix`.
  #
  # Copied rather than taken from the `utils` module argument for one concrete reason: everything
  # else in this file is a pure function of `lib` alone, callable straight from checks/ with plain
  # fixtures and no module-system evaluation, and reaching for `utils` would make the whole render
  # layer require one. It is eight lines and it has not changed shape in years.
  #
  # WHY IT IS NEEDED AT ALL: `ExecStart=` is NOT parsed by a shell. systemd does its own C-style
  # unquoting, and it expands `%`-specifiers (`%n`, `%t`, ...) and `$`-variables before exec. A
  # health command like `curl -f http://localhost/health` contains spaces and would otherwise
  # split into four argv entries; a `%` inside any value would be read as a specifier. `toJSON`
  # gives the double-quoted, backslash-escaped form systemd's parser accepts, and the two
  # replacements neutralise the specifier and variable syntax.
  escapeSystemdExecArg = arg:
    let
      s =
        if builtins.isPath arg then "${arg}"
        else if builtins.isString arg then arg
        else if builtins.isInt arg || builtins.isFloat arg then builtins.toString arg
        else throw "nixdocker: escapeSystemdExecArg only allows strings, paths and numbers, got ${builtins.typeOf arg}";
    in
    builtins.replaceStrings [ "%" "$" ] [ "%%" "$$" ] (builtins.toJSON s);
in
rec {
  inherit escapeSystemdExecArg;

  escapeSystemdExecArgs = lib.concatMapStringsSep " " escapeSystemdExecArg;

  # ── Image pinning: the one translation this repo shares with its podman sibling ───────────
  # THE QUESTION: given a repository, an optional human-readable tag, and an optional digest, what
  # literal string does `docker run` get? The tag is NEVER by itself sufficient to resolve the
  # image here -- see modules/containers.nix's assertion, which is what actually enforces that a
  # digest must be present unless a host explicitly opts out.
  mkImageRef = { repository, tag, digest, ... }:
    let
      tagPart = lib.optionalString (tag != null) ":${tag}";
      digestPart = lib.optionalString (digest != null) "@${digest}";
    in
    "${repository}${tagPart}${digestPart}";

  # ── `docker run` argv for one container ──────────────────────────────────────────────────
  #
  # ORDER MATTERS IN EXACTLY ONE PLACE: every flag comes before the image reference, and the
  # container's own command comes after it. Everything docker reads after the image name belongs
  # to the container's process, not to docker -- so `extraArgs` is appended to the FLAGS, ahead of
  # the image, and `command` is the only thing that lands behind it.
  #
  # Returned as a LIST, not a string, so callers (and checks/) can assert on individual arguments
  # rather than grepping a rendered line; `escapeSystemdExecArgs` above is what turns it into the
  # single `ExecStart=` value systemd wants.
  mkRunArgv = { docker, name, cfg }:
    let
      image = mkImageRef cfg.image;
    in
    [ docker "run" "--name=${name}" "--pull=${cfg.pull}" ]
    ++ lib.optional cfg.autoRemove "--rm"
    # `--log-driver` is stated rather than left implicit: the daemon-wide default is a fact about
    # /etc/docker/daemon.json, and a container whose logs a host expects to find with `journalctl`
    # should not depend on it.
    ++ lib.optional (cfg.logDriver != null) "--log-driver=${cfg.logDriver}"
    ++ lib.optional (cfg.entrypoint != null) "--entrypoint=${cfg.entrypoint}"
    ++ lib.optional (cfg.user != null) "--user=${cfg.user}"
    ++ lib.optional (cfg.workdir != null) "--workdir=${cfg.workdir}"
    ++ lib.optional (cfg.hostname != null) "--hostname=${cfg.hostname}"
    ++ lib.optional cfg.privileged "--privileged"
    ++ map (n: "--network=${n}") cfg.networks
    ++ lib.mapAttrsToList (k: v: "--env=${k}=${v}") cfg.environment
    ++ map (f: "--env-file=${f}") cfg.environmentFiles
    ++ map (v: "--volume=${v}") cfg.volumes
    ++ map (d: "--device=${d}") cfg.devices
    ++ map (p: "--publish=${p}") cfg.ports
    ++ lib.mapAttrsToList (k: v: "--label=${k}=${v}") cfg.labels
    ++ map (c: "--cap-add=${c}") cfg.capabilities.add
    ++ map (c: "--cap-drop=${c}") cfg.capabilities.drop
    ++ lib.optionals (cfg.health.cmd != null) [
      "--health-cmd=${cfg.health.cmd}"
      "--health-interval=${cfg.health.interval}"
      "--health-timeout=${cfg.health.timeout}"
      "--health-retries=${toString cfg.health.retries}"
      "--health-start-period=${cfg.health.startPeriod}"
    ]
    ++ cfg.extraArgs
    ++ [ image ]
    ++ cfg.command;

  # ── The shell a network's own unit runs ───────────────────────────────────────────────────
  #
  # THIS IS THE ONE IMPERATIVE CORNER OF THIS REPO, AND IT IS NOT HIDDEN. `docker network` has no
  # apply/reconcile verb: there is `create`, which fails if the name is taken, and `inspect`, which
  # answers whether it is. So "make sure this network exists" is a conditional create, and what it
  # does NOT do is reconcile a network that already exists with different options -- a subnet
  # changed in Nix does not move a live network. See the README's "What this repo cannot promise".
  #
  # `--label nixdocker.managed=true` is stamped on creation so a host can at least tell which
  # networks came from here, which is the cheapest honest thing available short of reconciliation.
  mkNetworkScript = { docker, name, cfg }:
    let
      createArgv = [ docker "network" "create" "--label=nixdocker.managed=true" ]
        ++ lib.optional (cfg.driver != null) "--driver=${cfg.driver}"
        ++ lib.optional (cfg.subnet != null) "--subnet=${cfg.subnet}"
        ++ lib.optional (cfg.gateway != null) "--gateway=${cfg.gateway}"
        ++ lib.optional cfg.internal "--internal"
        ++ lib.optional cfg.ipv6 "--ipv6"
        ++ cfg.extraArgs
        ++ [ name ];
    in
    ''
      set -euo pipefail

      if ${lib.escapeShellArgs [ docker "network" "inspect" name ]} >/dev/null 2>&1; then
        echo "nixdocker: network ${name} already exists -- left exactly as it is."
        echo "nixdocker: docker has no reconcile verb for networks; if its options need to change,"
        echo "nixdocker: remove it by hand (docker network rm ${name}) and let this unit recreate it."
        exit 0
      fi

      ${lib.escapeShellArgs createArgv}
    '';
}
