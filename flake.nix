{
  description = "meian.nvim - reflect macOS Light/Dark Mode into Neovim";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" ];
      perSystem =
        {
          pkgs,
          lib,
          ...
        }:
        let
          inherit (lib) fileset;
          swiftSrc = fileset.unions [
            ./swift
            ./Makefile
          ];
          nvimFiles = fileset.difference ./. (
            fileset.unions [
              swiftSrc
              (fileset.maybeMissing ./bin)
            ]
          );
          meian-watcher = pkgs.stdenv.mkDerivation {
            pname = "meian-watcher";
            version = "0.1.0";
            src = fileset.toSource {
              root = ./.;
              fileset = swiftSrc;
            };
            nativeBuildInputs = [ pkgs.swift ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              make build
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 bin/meian-watcher $out/bin/meian-watcher
              runHook postInstall
            '';
            meta = {
              description = "macOS Light/Dark Mode watcher for Neovim";
              platforms = lib.platforms.darwin;
              mainProgram = "meian-watcher";
            };
          };
          meian = pkgs.vimUtils.buildVimPlugin {
            pname = "meian.nvim";
            version = "0.1.0";
            src = fileset.toSource {
              root = ./.;
              fileset = nvimFiles;
            };
            postPatch = ''
              substituteInPlace lua/meian/init.lua \
                --replace-fail \
                  'local bundled_watcher_path = nil' \
                  'local bundled_watcher_path = "${meian-watcher}/bin/meian-watcher"'
            '';
            meta = {
              description = "Reflect macOS Light/Dark Mode into Neovim";
              platforms = lib.platforms.darwin;
            };
          };
        in
        {
          packages = {
            default = meian;
            inherit meian meian-watcher;
          };
        };
    };
}
