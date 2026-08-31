# Nix's own `tests/functional/dyn-drv/` oracle tests, vendored for reference
# (not run as-is -- they depend on the full functional-test harness's
# `_NIX_TEST_BUILD_DIR`/`common.sh` machinery, which isn't self-contained
# enough to vendor wholesale). `dyndrv`'s own tests (../  ) reimplement the
# same scenarios using nixpkgs directly, cross-checked against these.
#
# Update by copying the current files from a nix checkout, e.g.:
#   cp ~/nix-src/tests/functional/dyn-drv/{text-hashed-output.nix,non-trivial.nix,eval-outputOf.sh} .
#
# Files here:
#   text-hashed-output.nix  -- the canonical minimal example: a CA drv
#                              whose output is another drv's .drv file.
#                              Source for dyndrv's own text-hashed-output.nix
#                              test.
#   non-trivial.nix         -- a 5-node diamond graph (a -> b,c -> d -> e)
#                              built entirely via `nix derivation add`
#                              inside a recursive-nix sandbox. Source for
#                              dyndrv's own non-trivial.nix test.
#   eval-outputOf.sh        -- locks in outputOf's two permanent rough
#                              edges (string-only, DrvDeep rejection) that
#                              mkOutputOf.nix must paper over. See
#                              ../../nix/lib/mkOutputOf.nix.
