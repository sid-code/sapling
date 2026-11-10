{
  description = "Experimental Nix packaging for EdenFS (facebook/sapling OSS build)";

  # Resolve through the system flake registry so we get the same nixpkgs
  # (26.11 / "Zokor") that already provides the Meta C++ stack at
  # 2026.07.27.00.  Pin to a revision for reproducible builds.
  inputs.nixpkgs.url = "nixpkgs";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: prev: {
        edenfs = final.callPackage ./nix/edenfs/package.nix {
          edencommon = final.callPackage ./nix/edencommon.nix { };
        };
      };

      nixosModules = {
        edenfs = ./nix/edenfs/module.nix;
        default = self.nixosModules.edenfs;
      };

      packages = forAllSystems (pkgs: {
        # Phase 1 target: the C++ daemon + Rust static lib + edenfsctl
        # (no Python CLI, no tests).  The source is pinned inside package.nix
        # to the Sapling 2026-11-03 release, which matches the packaged Meta
        # stack except for edencommon (bumped here for GlobPath).
        edenfs = pkgs.callPackage ./nix/edenfs/package.nix {
          edencommon = pkgs.callPackage ./nix/edencommon.nix { };
        };

        # Handy for validating the 56 git outputHashes without compiling
        # anything: `nix build .#cargo-deps` only fetches and unpacks all
        # locked crates and git repositories.
        cargo-deps = self.packages.${pkgs.stdenv.hostPlatform.system}.edenfs.cargoDeps;

        default = self.packages.${pkgs.stdenv.hostPlatform.system}.edenfs;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.edenfs ];
          packages = with pkgs; [
            cargo
            rustc
            rust-analyzer
            cmake
            ninja
            nix-prefetch-git
          ];
        };
      });
    };
}
