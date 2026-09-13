{
  description = "dyndrv: shared library and tooling for Nix dynamic derivations";

  inputs = {
    nixpkgs.follows = "nix/nixpkgs";
    nix.url = "github:nixos/nix";
  };

  outputs =
    { self, nixpkgs, nix }:
    {

      # Re-exports the raw `nixpkgs` input's own `legacyPackages` under
      # `self` -- the standard flake output name for this shape, and
      # what `try-it-out/`'s own examples/benchmarks (and `nix/tests/
      # run-tests.sh`, `rust/dyndrv-shim/*.sh`) all resolve `pkgs` from
      # via `(builtins.getFlake (toString ...)).legacyPackages.
      # ${system}`, so `nix develop`/`nix build .#...` and a bare `nix
      # build -f try-it-out/examples/....nix` always agree on which
      # nixpkgs revision/stdenv they're using.
      legacyPackages = nixpkgs.legacyPackages;

      lib = builtins.mapAttrs (system: pkgs:
        import ./nix {
          inherit pkgs;
          lib = pkgs.lib;
        }
      ) nixpkgs.legacyPackages;

      # The 3 unit-style checks from `nix/tests/default.nix`, plus one
      # entry per example this repo's own CI already builds (`example-
      # NN[-suffix]`, matching each file's own numeric prefix) -- turns
      # what used to be individual `run-nix.sh build -f <file>` shell
      # lines in `.github/workflows/ci.yml` into real flake checks,
      # buildable directly via `nix build .#checks.<system>.<name>`
      # (confirmed working through the SAME patched-Nix + alt-store +
      # `builder-rpc-v0` mechanism `run-nix.sh` already encapsulates).
      # `07-accelerate-real-package.nix` returns `{ accelerated;
      # patchOutput; }`, not a single derivation -- split into two
      # separate checks accordingly, matching how CI already builds it
      # via two separate attr-path invocations.
      checks = builtins.mapAttrs (system: pkgs:
        (import ./nix/tests {
          inherit pkgs;
          lib = pkgs.lib;
          dyndrv = self.lib.${system};
        })
        // {
          example-01 = import ./try-it-out/examples/01-hello-dynamic-drv.nix { inherit pkgs; };
          example-02 = import ./try-it-out/examples/02-fallback-ifd.nix { inherit pkgs; };
          example-03-graph-of-two = import ./try-it-out/examples/03-graph-of-two.nix { inherit pkgs; };
          example-03-graph-of-three = import ./try-it-out/examples/03-graph-of-three.nix { inherit pkgs; };
          example-03-graph-with-groups = import ./try-it-out/examples/03-graph-with-groups.nix { inherit pkgs; };
          example-03-graph-groupby-directory =
            import ./try-it-out/examples/03-graph-groupby-directory.nix { inherit pkgs; };
          example-05 = import ./try-it-out/examples/05-accelerate-stdenv.nix { inherit pkgs; };
          example-06 = import ./try-it-out/examples/06-accelerate-stdenv-module.nix { inherit pkgs; };
          example-07-accelerated =
            (import ./try-it-out/examples/07-accelerate-real-package.nix { inherit pkgs; }).accelerated;
          example-07-patch-output =
            (import ./try-it-out/examples/07-accelerate-real-package.nix { inherit pkgs; }).patchOutput;
        }
      ) nixpkgs.legacyPackages;

      packages = builtins.mapAttrs (system: pkgs: {
          example = import ./try-it-out/examples/08-accelerate-example-dir.nix { inherit pkgs; };

          default =
            let
              patchedNix = import ./try-it-out/patched-nix.nix { inherit system; };
            in
            pkgs.writeShellScriptBin "nix" ''
              : "''${DYNDRV_STORE:=/tmp/dyndrv-store}"
              mkdir -p "$DYNDRV_STORE"
              exec ${patchedNix}/bin/nix \
                --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix" \
                --extra-system-features "builder-rpc-v0" \
                --store "local?root=$DYNDRV_STORE" \
                "$@"
            '';
        }
      ) nixpkgs.legacyPackages;

      devShells = builtins.mapAttrs (system: pkgs: {
          dyndrv-shim =
            let
              lib = pkgs.lib;
              dyndrvLib = self.lib.${system};
              dyndrvShim = import ./rust/dyndrv-shim.nix { inherit pkgs; };
              shim = dyndrvLib.shim.devShell {
                stdenv = pkgs.stdenv;
                inherit dyndrvShim;
                autoforce = true;
              };
            in
            pkgs.mkShellNoCC {
              name = "dyndrv-shim-devshell";
              packages = [
                pkgs.gnumake
                pkgs.coreutils
              ];
              shellHook = shim.shellHook;
            };

          default = self.devShells.${system}.dyndrv-shim;
        }
      ) nixpkgs.legacyPackages;
    };
}
