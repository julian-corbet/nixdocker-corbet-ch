{
  description = "Typed Nix options for digest-pinned docker containers, and a declarative dockerd, on a plane that has no `virtualisation.*` -- rendered to ordinary systemd units, with the daemon off unless a host says otherwise.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Used ONLY by `checks` -- `systemManagerModules.nixdocker` itself takes no input from here, the
  # same way `nixosModules.nixdocker` does not depend on this flake's nixpkgs. It is here because
  # system-manager is the plane this repo is actually deployed on, and the claim "one declaration
  # renders on both planes" is worth nothing unevaluated: without it, `nix flake check` would prove
  # the plane nixdocker is NOT used on and take the live one on faith.
  inputs.system-manager.url = "github:numtide/system-manager";
  inputs.system-manager.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, system-manager }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
      # TWO PLANES, ONE DECLARATION. `modules/nixdocker.nix` holds the option surface and all of
      # the wiring that is true on both (render the argv -> write the systemd unit -> order it
      # against the daemon and the networks it needs); each module below is the thin backend for
      # one plane, and each one's own header says exactly what it adds and why that part could not
      # be shared. A container is declared the same way on either.
      nixosModules.nixdocker = ./modules/nixos.nix;
      nixosModules.default = self.nixosModules.nixdocker;

      systemManagerModules.nixdocker = ./modules/system-manager.nix;
      systemManagerModules.default = self.systemManagerModules.nixdocker;

      # nixdocker.packages -- declared host tooling (docker-compose, docker-buildx), NOT part of
      # the plane-neutral wiring above and not pulled in by
      # nixosModules.nixdocker/systemManagerModules.nixdocker on its own. A separate opt-in
      # module, same shape as nixiam's own packages.nix/.arch.nix/.nixos.nix trio -- see
      # modules/packages.nix's header for why this repo declares packages at all.
      systemManagerModules.packages = ./modules/packages.arch.nix;
      nixosModules.packages = ./modules/packages.nixos.nix;

      # The pure pieces, exposed for inspection or reuse without a module-system evaluation. There
      # is deliberately no `lib.build` here, unlike in this repo's podman sibling: podman ships a
      # real systemd generator that nixpods runs at build time, and docker ships nothing of the
      # kind, so there is no build step to expose. See modules/nixdocker.nix's header.
      lib = {
        render = import ./lib/render.nix { inherit lib; };
        options = import ./lib/options.nix { inherit lib; };
      };

      checks = forAllSystems (system:
        import ./checks
          {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit lib system;
            nixdockerModule = self.nixosModules.nixdocker;
            packagesModule = self.nixosModules.packages;
          }
        // {
          system-manager-eval-tests = import ./checks/system-manager-eval-tests.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            systemManagerModule = self.systemManagerModules.nixdocker;
            systemManagerLib = system-manager.lib;
          };
        }
      );

      # NOTE ON WHAT IS NOT HERE. nixpods carries a deliberately-failing
      # `packages.<system>.demo-malformed-container-fails-build`: a malformed quadlet fed through
      # the real generator, left buildable so it can be watched fail. There is no equivalent here
      # and there cannot be, because there is no generator to feed -- nixdocker's negative proofs
      # are all at EVALUATION time (an unpinned image, a dangling network reference, a `--restart`
      # smuggled through `extraArgs`, a `Type=oneshot` unit with a `Restart=` systemd would refuse
      # to load), and checks/default.nix proves each of them fails by name.

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
