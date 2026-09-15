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
      # via two separate attr-path invocations. Examples 17-33 are the
      # regression fixtures for tasks #130-133 (cwd-relative-path-frame
      # mismatch, CMake compiler-flag-probe passthrough, `autoreconfHook`
      # phase-dropping, `finalAttrs.finalPackage`) plus eleven follow-up
      # argv-shape/phase-ordering/dependency-wiring/structuredAttrs
      # regressions (compile+link-in-one-step, `-MT`/`-MF` values
      # misidentified as the source file, `ar`/`ranlib` probe-invocation
      # crashes, cmake+make's own out-of-tree install failure, `ar`'s
      # own real store-path inputs never wired as derivation deps, a
      # `-Wl,`-glued flag's own embedded path never unglued before
      # computing its output directory, `dyndrvRestoreOutput` running
      # too late for a `postInstall` that reads/writes `$out` directly,
      # `ar`/`ranlib` probes with a non-`-`-prefixed positional value
      # elsewhere in argv, multi-output restore never redistributing
      # ordinary `bin`/`lib` content, `__structuredAttrs = true`
      # silently defeating `sandboxedDrv`'s own `out =
      # dyndrvPlaceholderOut` override, cmake's `install(EXPORT ...)`
      # baking that SAME literal placeholder path into a generated
      # target-import file's `_IMPORT_PREFIX`, never rewritten before a
      # caller's own `postFixup substituteInPlace` expects to find the
      # real `$out`, and meson's own `testfile.<suffix>`-named compiler-
      # check probes not being recognized as passthrough-eligible), each
      # confirmed failing before its own fix and passing after -- see
      # each file's own header comment for the
      # exact bug it guards against.
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
          example-17 = import ./try-it-out/examples/17-accelerate-cwd-mismatch.nix { inherit pkgs; };
          example-18 = import ./try-it-out/examples/18-accelerate-cmake-probe.nix { inherit pkgs; };
          example-19 = import ./try-it-out/examples/19-accelerate-autoreconf.nix { inherit pkgs; };
          example-20 = import ./try-it-out/examples/20-accelerate-final-package.nix { inherit pkgs; };
          example-21 = import ./try-it-out/examples/21-accelerate-compile-and-link-one-step.nix { inherit pkgs; };
          example-22 = import ./try-it-out/examples/22-accelerate-mt-mf-absolute-source.nix { inherit pkgs; };
          example-23 = import ./try-it-out/examples/23-accelerate-ar-ranlib-probe.nix { inherit pkgs; };
          example-24 = import ./try-it-out/examples/24-accelerate-cmake-make-outoftree.nix { inherit pkgs; };
          example-25 = import ./try-it-out/examples/25-accelerate-ar-multi-input.nix { inherit pkgs; };
          example-26 = import ./try-it-out/examples/26-accelerate-wl-dependency-file.nix { inherit pkgs; };
          example-27 = import ./try-it-out/examples/27-accelerate-postinstall-reads-out.nix { inherit pkgs; };
          example-28 = import ./try-it-out/examples/28-accelerate-ar-ranlib-plugin-probe.nix { inherit pkgs; };
          example-29 = import ./try-it-out/examples/29-accelerate-multioutput-lib-restore.nix { inherit pkgs; };
          example-31 = import ./try-it-out/examples/31-accelerate-structured-attrs.nix { inherit pkgs; };
          example-32 = import ./try-it-out/examples/32-accelerate-cmake-import-prefix.nix { inherit pkgs; };
          example-33 = import ./try-it-out/examples/33-accelerate-meson-probe.nix { inherit pkgs; };
        }
      ) nixpkgs.legacyPackages;

      packages = builtins.mapAttrs (system: pkgs: {
          example = import ./try-it-out/examples/08-accelerate-example-dir.nix { inherit pkgs; };

          # The `Rpc`-mode wrapper dir `nix/lib/shim/devShell.nix`'s own
          # `wrapperDir` produces (`bin/cc`/`c++`/`ar`/`ranlib`, backed
          # by the compiled `rust/dyndrv-shim`) -- with `autoforce =
          # false` (registers, never realizes), matching what every one
          # of `rust/dyndrv-shim/{parity-test-lib,cross-mode-reuse,
          # thunk-nix-multinode-test,drv-thunk-multinode-test}.sh`
          # actually needs. Exposed as a real flake output rather than
          # each script computing it independently via its own inline
          # `nix build --expr '... builtins.getFlake "$DYNDRV_ROOT" ...'`
          # -- `builtins.getFlake` on a local path is ALWAYS treated as
          # an unlocked flake reference once its result is actually
          # used (confirmed by direct reproduction: true regardless of
          # `?rev=` or a clean git tree), so every one of those scripts
          # needed `--impure` just to resolve `pkgs` this way. Building
          # THIS output via `.#packages.<system>.rpc-wrapper` instead
          # needs no `--impure` at all, since `pkgs` here is supplied
          # by this SAME flake's own `packages = builtins.mapAttrs
          # (system: pkgs: ...)`, exactly like every `checks.<system>.
          # example-*` entry above.
          rpc-wrapper =
            let
              dyndrvShim = import ./rust/dyndrv-shim.nix { inherit pkgs; };
            in
            (self.lib.${system}.shim.devShell {
              stdenv = pkgs.stdenv;
              inherit dyndrvShim;
              autoforce = false;
            }).wrapperDir;

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
