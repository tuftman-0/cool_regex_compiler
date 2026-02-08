{
  description = "Zig development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            # Common development tools
            zls # Zig Language Server
            gdb
            lldb
          ];

          shellHook = ''
            echo "Zig development environment loaded!"
            echo "Zig version: $(zig version)"

            # Make Zig caches writable (prevents /build/tmp... AccessDenied)
            mkdir -p "$HOME/.cache/zig" "$HOME/.cache/zig-local" "$HOME/.cache/zls"
            export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig"
            export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local"

            # Optional: also avoid tools choosing /build for temp files
            export TMPDIR="$HOME/.cache/tmp"
            mkdir -p "$TMPDIR"
          '';
        };
      });
}
