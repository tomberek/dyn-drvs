{
  description = "dyndrv: shared library and tooling for Nix dynamic derivations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
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
          pkgs.mkShell {
            packages = with pkgs; [
              cargo
              rustc
              rust-analyzer
              clippy
              jq
            ];
          };
      });
    };
}
