{
  description = "dyndrv: shared library and tooling for Nix dynamic derivations";

  inputs = {
    nixpkgs.follows = "nix/nixpkgs";
    nix.url = "github:nixos/nix";
  };

  outputs =
    { self, nixpkgs, nix }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      lib = forAllSystems (
        system:
        import ./nix {
          pkgs = nixpkgs.legacyPackages.${system};
          lib = nixpkgs.lib;
        }
      );

      checks = forAllSystems (
        system:
        import ./nix/tests {
          pkgs = nixpkgs.legacyPackages.${system};
          lib = nixpkgs.lib;
          dyndrv = self.lib.${system};
        }
      );

      # `nix build .#example` (or `.#packages.<system>.example`): the
      # real, checked-in `example/` C++ project, accelerated via
      # `dyndrv.accelerate.mkAcceleratedStdenv` -- `try-it-out/examples/
      # 08-accelerate-example-dir.nix`'s own content, unmodified (that
      # file already resolves everything it needs via `<nixpkgs>`/
      # relative imports, exactly like every other example in that
      # directory; this output just makes it reachable as `.#example`
      # too).
      #
      # STILL NEEDS an isolated alt store + a `builder-rpc-v0`-capable
      # driving Nix to actually build -- the ambient system Nix daemon
      # doesn't support it, and no `packages.<system>` wiring changes
      # that structural requirement. Build it the same way as any other
      # example, just pointed at this flake output instead of a
      # `-f <file>` path:
      #
      #   try-it-out/run-nix.sh build --impure --no-link --print-out-paths .#example
      packages = forAllSystems (
        _: {
          example = import ./try-it-out/examples/08-accelerate-example-dir.nix;
        }
      );

      devShells = forAllSystems (system: {
        # `nix develop .#nixgg` (previously `.#default`): the original
        # nixgg-style shell, no compiled shim wrappers at all -- just a
        # patched Nix pointed at an alt local store. Kept under its own
        # name for anyone who still wants exactly this, unshimmed.
        nixgg =
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in

          pkgs.mkShellNoCC {
            name = "nixgg-shell";
            packages = [
              pkgs.gnumake
              pkgs.coreutils
              pkgs.bash
              nix.packages.${system}.nix
            ];
            shellHook = ''

              : "''${NIXGG_STORE:=local?root=/tmp/dyn-drv-store}"
              echo "nix shell: prepending patched Nix and pointing NIX_CONFIG at an alt store" >&2
              export NIX_CONFIG="
              extra-experimental-features = nix-command flakes impure-derivations ca-derivations dynamic-derivations configurable-impure-env
              extra-system-features = builder-rpc-v0
              store = ''${NIXGG_STORE}
              "
            '';
          };

        # `nix develop` (default) / `nix develop .#dyndrv-shim`: a real
        # `cc`/`ar`/`ranlib` toolchain backed by the compiled `rust/
        # dyndrv-shim` binary (see `nix/lib/shim/devShell.nix`'s own
        # header comment) -- registers (and, with `DYNDRV_AUTOFORCE=1`,
        # realizes) real derivations for every compile/archive step run
        # in this shell, over an ordinary UNRESTRICTED daemon connection
        # (`Rpc` mode, auto-detected: no `builder-rpc-v0` sandbox env
        # vars present outside a real sandboxed build). Verified
        # end-to-end (compile, archive, ranlib-index, link, run) against
        # a real two-file C program.
        dyndrv-shim =
          let
            pkgs = nixpkgs.legacyPackages.${system};
            lib = nixpkgs.lib;
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
      });
    };
}
