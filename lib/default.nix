{
  nixpkgs,
  nixpkgs-darwin ? nixpkgs,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
  harbor-meta ? null,
  opencodeLspLib ? null,
}: let
  nixLib = nixpkgs.lib;
  pythonLib = import ./python.nix {
    inherit
      nixLib
      pyproject-nix
      uv2nix
      pyproject-build-systems
      opencodeLspLib
      ;
    metaDevShell =
      if harbor-meta != null
      then harbor-meta.lib.devShell
      else null;
  };
in
  pythonLib
  // rec {
    timezone = harbor-meta.lib.timezone;
    opencode =
      if harbor-meta != null
      then harbor-meta.lib.opencode
      else throw "harbor-py: opencode helpers require the harbor-meta flake input";

    # Keep the shell contract aligned with the four maintained native Harbor
    # systems. nixpkgs flakeExposed also includes experimental platforms whose
    # Python/tooling package sets are not valid development environments.
    allSystems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    packageSystems = [
      "x86_64-linux"
      "aarch64-darwin"
    ];

    forAllSystems = f: nixLib.genAttrs allSystems f;
    forPackageSystems = f: nixLib.genAttrs packageSystems f;

    mkPkgs = {
      system,
      overlays ? [],
      config ? {},
    }:
      import (
        if system == "x86_64-darwin"
        then nixpkgs-darwin
        else nixpkgs
      ) {
        inherit system overlays;
        config =
          {
            allowUnfree = true;
          }
          // config;
      };
  }
