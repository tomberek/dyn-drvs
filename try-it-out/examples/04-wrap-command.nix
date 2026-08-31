# Demonstrates dyndrv.shim.wrapCommand: intercepting a toolchain command
# so each invocation registers itself as a dynamically-produced
# derivation, realized immediately (resolveInputs = "materialize", the
# only mode implemented in v0.2 -- see wrapCommand.nix's header comment
# for why this needs the recursive-nix backend specifically).
#
# This example wraps a fake "compiler" that uppercases its input --
# standing in for `cc` in the real accelerator use case. Building this
# derivation runs the wrapper script against a real input file, which:
#   1. serializes its own argv and instantiates `toNode` against it
#   2. registers the resulting derivation via `nix derivation add`
#   3. realizes it immediately via `nix-store --realise`
#   4. copies the real result to the path the caller expects
#
# Run with:
#   nix build --extra-experimental-features "nix-command dynamic-derivations ca-derivations recursive-nix" \
#     --impure -f try-it-out/examples/04-wrap-command.nix

let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };

  input = pkgs.writeText "wrap-command-input.txt" "hello from wrapCommand\n";

  # argv (as the wrapper script sees it, WITHOUT the command name itself)
  # is ["-c" "<input>" "-o" "<output>"] -- see wrapCommand.nix's own
  # header comment for this indexing convention.
  toNode = ''
    argv:
    let
      input = builtins.elemAt argv 1;
      inputBasename = builtins.baseNameOf input;
    in
    {
      drvJson = builtins.toJSON {
        name = "wrap-command-compiled";
        system = builtins.currentSystem;
        builder = "/bin/sh";
        args = [ "-c" "${pkgs.coreutils}/bin/tr a-z A-Z < ''${input} > $out" ];
        env.out = builtins.placeholder "out";
        inputs = {
          drvs = { };
          srcs = [ inputBasename "${builtins.baseNameOf "${pkgs.coreutils}"}" ];
        };
        outputs.out = { method = "nar"; hashAlgo = "sha256"; };
        version = 4;
      };
      outputArg = 3;
    }
  '';

  shim = dyndrv.shim.wrapCommand {
    command = "fakecc";
    inherit toNode;
  };
in
pkgs.runCommand "wrap-command-example"
  {
    requiredSystemFeatures = [ "recursive-nix" ];
    nativeBuildInputs = [ pkgs.nix ];
    wrapperScript = shim.wrapperScript;
    passAsFile = [ "wrapperScript" ];
  }
  ''
    install -Dm755 "$wrapperScriptPath" "$TMPDIR/fakecc"
    "$TMPDIR/fakecc" -c ${input} -o "$out"
  ''
