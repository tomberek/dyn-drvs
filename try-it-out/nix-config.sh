#!/usr/bin/env bash
# source-able: sets NIX_CONFIG with the experimental-features/system-features
# dyndrv needs, so users don't have to remember the exact flag spelling
# (confusion about `ca-derivations` vs `ca-derivation`-style casing, and
# which of dynamic-derivations/recursive-nix/builder-rpc-v0 need to be
# combined, was a real source of friction across the surveyed projects).
#
# Usage: source try-it-out/nix-config.sh

export NIX_CONFIG="extra-experimental-features = nix-command ca-derivations dynamic-derivations recursive-nix
extra-system-features = builder-rpc-v0"
