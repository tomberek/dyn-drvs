# Regression fixture for task #141: `ar`'s deferred record never
# declares its own `.o` positional inputs as store-path dependencies
# when those inputs are REAL, already-resolved files rather than
# still-pending stubs -- confirmed via real nixpkgs openjpeg (nix-dyn-
# drv/overlay#13): the first `ar`-driven static-lib link fails with
# `ar: /nix/store/<hash>-thread.c.o: No such file or directory`, and
# `nix derivation show` on the registered `ar` derivation shows
# `inputs.drvs = {}` -- none of its real `.o` inputs are wired as a
# dependency.
#
# WHY the inputs are real files, not pending stubs: cmake's generated
# compile command always names its source via an ABSOLUTE path (`-c
# /build/source/lib/thread.c`), which `mkAcceleratedStdenv.nix`'s own
# "PASSTHROUGH for a compile whose source is still an absolute path"
# branch runs SYNCHRONOUSLY (a real, immediate gcc invocation, never
# deferred into a batch-pending stub) -- so every one of cmake's own
# per-TU `.o` outputs is a REAL file on disk by the time `ar` archives
# them, not a stub `shim.collectStubs` would otherwise wire as a cross-
# unit dependency. `wrapCommand.nix`'s own `rewrittenArgs` step then
# substitutes each real `.o`'s literal relative path for its real
# store path (`nix store add-file`) before `ar`'s own `toNode` ever
# sees `argv` -- exactly the shape `ccToNode`'s `extraStorePaths` scan
# already handles, but `arToNode` never had an equivalent scan for.
#
# This fixture reproduces cmake's own absolute-source-path compile
# convention directly (`cc -c /build/.../a.c -o a.o`, mirroring the
# `-MD -MT a.o -MF a.o.d -o a.o -c /build/.../a.c` shape cmake actually
# emits) followed by an `ar` step over the resulting REAL `.o` files --
# confirmed failing before the fix (`ar: /nix/store/<hash>-a.c.o: No
# such file or directory`), passing after.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/25-accelerate-ar-multi-input.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-ar-multi-input-src" { } ''
    mkdir -p $out
    cat > $out/a.c <<'EOF'
    int a_fn(void) { return 1; }
    EOF
    cat > $out/b.c <<'EOF'
    int b_fn(void) { return 2; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: libfoo.a
    a.o: a.c
    	$(CC) -MD -MT a.o -MF a.o.d -o a.o -c $(CURDIR)/a.c
    b.o: b.c
    	$(CC) -MD -MT b.o -MF b.o.d -o b.o -c $(CURDIR)/b.c
    libfoo.a: a.o b.o
    	$(AR) qc libfoo.a a.o b.o
    	$(RANLIB) libfoo.a
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-ar-multi-input";
      version = "1.0";
      inherit src;
      installPhase = ''
        mkdir -p $out
        cp libfoo.a $out/
      '';
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
