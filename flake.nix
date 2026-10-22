{
  description = "Reusable Python uv2nix and pyproject-nix infrastructure for Nix flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    flake-utils.url = "github:numtide/flake-utils";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };

    harbor-meta = {
      url = "git+https://github.com/caniko/harbor-meta.git?ref=trunk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    meta-harbor.follows = "harbor-meta";

    nix-opencode-lsp = {
      url = "git+https://github.com/caniko/nix-opencode-lsp.git?ref=trunk";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-darwin,
    flake-utils,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
    harbor-meta,
    nix-opencode-lsp,
    treefmt-nix,
    git-hooks,
    harborFormatting ? null,
    ...
  }: let
    lib = import ./lib {
      inherit
        nixpkgs
        nixpkgs-darwin
        pyproject-nix
        uv2nix
        pyproject-build-systems
        harbor-meta
        ;
      opencodeLspLib = nix-opencode-lsp.lib;
    };
  in
    {
      inherit lib;
      treefmtModules.python = ./nix/treefmt/python.nix;

      templates.default = {
        path = ./templates/default;
        description = "Python uv project with harbor-py";
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = lib.mkPkgs {inherit system;};
        treefmt = treefmt-nix.lib.evalModule pkgs (import ./nix/treefmt.nix);
      in {
        formatter = treefmt.config.build.wrapper;

        devShells = {
          opencode-lsp-python = nix-opencode-lsp.lib.mkShell {
            inherit pkgs;
            profiles = ["python"];
          };
          default = self.devShells.${system}.opencode-lsp-python.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [treefmt.config.build.wrapper];
          });
        };

        checks =
          import ./checks {
            inherit self pkgs system nixpkgs nixpkgs-darwin treefmt-nix git-hooks;
            harbor = lib;
            meta = harbor-meta.lib;
          }
          // {
            formatting =
              if harborFormatting == null
              then treefmt.config.build.check self
              else harborFormatting system;
          };
      }
    );
}
