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

      devShells = forAllSystems (system: {
        default =
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

        # `nix develop .#dyndrv-shim`: a real `cc`/`ar`/`ranlib` toolchain
        # backed by the compiled `rust/dyndrv-shim` binary (see
        # `nix/lib/shim/devShell.nix`'s own header comment) -- registers
        # (and, with `DYNDRV_AUTOFORCE=1`, realizes) real derivations for
        # every compile/archive step run in this shell, over an ordinary
        # UNRESTRICTED daemon connection (`Rpc` mode, auto-detected: no
        # `builder-rpc-v0` sandbox env vars present outside a real
        # sandboxed build). Verified end-to-end (compile, archive,
        # ranlib-index, link, run) against a real two-file C program.
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
      });
    };
}
