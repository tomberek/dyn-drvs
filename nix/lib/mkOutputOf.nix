{ pkgs, lib, self }:

# Wraps `builtins.outputOf`, papering over its two documented rough edges
# (locked in by Nix's own `tests/functional/dyn-drv/eval-outputOf.sh`):
#
#  1. It requires a literal string, not a derivation attrset that could
#     coerce to one -- Nix's own test comment: "we might liberalise this in
#     the future... adding a test so we don't liberalise it by accident."
#  2. It rejects strings whose context is `DrvDeep` (i.e. `drv.drvPath`,
#     which tracks "the complete source and binary closure"), with the
#     error: "has a context which refers to a complete source and binary
#     closure. This is not supported at this time." The fix is
#     `builtins.unsafeDiscardOutputDependency`, which every surveyed project
#     (drowse, nixgg, dgd, sandstone) had independently rediscovered.
#
# `mkOutputOf` accepts either a derivation or a `.drvPath`/string directly,
# so callers never have to reach for `unsafeDiscardOutputDependency`
# themselves.

drv: outputName:

let
  drvPath = if lib.isDerivation drv then drv.drvPath else drv;

  # `unsafeDiscardOutputDependency` is a no-op on a string that's already
  # `Opaque` (e.g. one produced by an earlier `outputOf` call, for chaining),
  # so it's always safe to apply unconditionally rather than trying to detect
  # which context kind we already have.
  discarded = builtins.unsafeDiscardOutputDependency drvPath;
in
builtins.outputOf discarded outputName
