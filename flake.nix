{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable-small";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Helper to provide system-specific attributes
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs allSystems (
          system:
          f {
            pkgs = import nixpkgs { inherit system; };
            system = system;
          }
        );
    in
    {
      devShells = forAllSystems (
        {
          pkgs,
          system,
        }:
        {
          default = pkgs.mkShell {
            nativeBuildInputs = [
              pkgs.zig
              pkgs.zls
              pkgs.pkg-config
              pkgs.sdl3
              pkgs.emscripten # wasm target, 1GiB+
            ];

            env = {
              SYSROOT = "${pkgs.emscripten}/share/emscripten/cache/sysroot";
              EM_CACHE = "/tmp";
            };
          };
        }
      );
    };
}
