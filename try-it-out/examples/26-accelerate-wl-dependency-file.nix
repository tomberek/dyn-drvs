# Regression fixture for task #142: `wrapCommand.nix`'s own "pre-
# create output dirname" loop treats a `-Wl,`-glued flag as a literal
# path instead of unglueing it first.
#
# Confirmed via real nixpkgs libwebp/leveldb/brotli/libssh (originally
# misdiagnosed, in the ~/overlay showcase repo's own survey findings,
# as `discoverTree` itself misstaging multi-subdirectory cmake source
# trees): cmake+ninja's own generated link line passes
# `-Wl,--dependency-file=CMakeFiles/<target>.dir/link.d` -- ONE glued
# argv token -- and the loop that pre-creates every relative OUTPUT
# path's own parent directory (so a linker's own `--dependency-file`
# write, an output nothing else in argv references as an INPUT,
# doesn't fail with "No such file or directory") computed the WRONG
# dirname: the flag's own literal text minus its last path segment
# (`-Wl,--dependency-file=CMakeFiles/<target>.dir`, confirmed via
# direct reproduction: a spurious directory with EXACTLY that name
# showed up in the staged tree) instead of the REAL relative directory
# the linker actually needs (`CMakeFiles/<target>.dir`), which was
# never created at all -- `ld.bfd: cannot open dependency file
# CMakeFiles/<target>.dir/link.d: No such file or directory`.
#
# This fixture reproduces the exact `-Wl,--dependency-file=...` shape
# directly, in a nested subdirectory (mirroring cmake's own
# `CMakeFiles/<target>.dir/` convention) -- confirmed failing before
# the fix, passing after.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/26-accelerate-wl-dependency-file.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-wl-dependency-file-src" { } ''
    mkdir -p $out
    cat > $out/a.c <<'EOF'
    int a_fn(void) { return 1; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: prog
    CMakeFiles/prog.dir/a.c.o: a.c
    	mkdir -p CMakeFiles/prog.dir
    	$(CC) -c a.c -o CMakeFiles/prog.dir/a.c.o
    prog: CMakeFiles/prog.dir/a.c.o
    	$(CC) -shared -Wl,--dependency-file=CMakeFiles/prog.dir/link.d -o prog CMakeFiles/prog.dir/a.c.o
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-wl-dependency-file";
      version = "1.0";
      inherit src;
      installPhase = ''
        mkdir -p $out
        cp prog $out/
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
