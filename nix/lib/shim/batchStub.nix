{ pkgs, lib, self }:

# Shared on-disk stub format for `shim.wrapCommand`'s `defer` mode and
# `shim.wrapArchiver`'s collecting pass -- the marker a deferred compile's
# wrapper writes at its expected output path instead of a real object
# file, later read back by `wrapArchiver` to find the real compile to run.
#
# Mirrors nixgg's `drvref`/`batchpending` Go packages. Defined once here
# (not hand-rolled separately in the writer and the reader) so the two
# sides can't drift out of sync.
#
# Format (a plain regular file, never a symlink -- nothing exists yet at
# the eventual output for a symlink to point at, and a dangling symlink
# fails a plain `test -e`):
#
#   #!dyndrv-batch-pending
#   <absolute path to a JSON record file, written separately>
#
# The record file's own JSON shape is defined by the writer
# (`wrapCommand.nix`'s `defer` branch) and consumed by the reader
# (`wrapArchiver.nix`) -- this file only defines the outer stub.

let
  header = "#!dyndrv-batch-pending";
in
{
  inherit header;

  # Writes a stub at $1 pointing at record file $2.
  writeStubFn = ''
    dyndrv_write_batch_stub() {
      local outputPath="$1" recordPath="$2"
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$outputPath")"
      printf '%s\n%s\n' '${header}' "$recordPath" > "$outputPath"
    }
  '';

  # Prints the record path if $1 is a stub, nothing otherwise -- callers
  # check `[ -n "$(dyndrv_read_batch_stub "$path")" ]`. Never errors on a
  # missing/non-stub/binary file, since a real `.o`/`.a` must never be
  # misclassified as pending. Uses plain `read`, not `sed`/`head` --
  # `sed` isn't part of `coreutils`.
  readStubFn = ''
    dyndrv_read_batch_stub() {
      local path="$1" firstLine restLine
      [ -f "$path" ] || return 0
      { IFS= read -r firstLine; IFS= read -r restLine; } < "$path" 2>/dev/null
      [ "$firstLine" = '${header}' ] || return 0
      printf '%s\n' "$restLine"
    }
  '';
}
