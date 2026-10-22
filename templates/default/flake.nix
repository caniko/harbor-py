{
  description = "Python uv project — powered by harbor-py";

  inputs = {
    harbor.url = "git+https://github.com/caniko/harbor.git?ref=feat/harbor-monorepo-components&rev=7d99eb50c52d0a941e2996b97c469b32a7657ef4";
    nixpkgs.follows = "harbor/nixpkgs";
    nixpkgs-darwin.follows = "harbor/nixpkgs-darwin";
    treefmt-nix.follows = "harbor/treefmt-nix";
    git-hooks.follows = "harbor/git-hooks";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-darwin,
    harbor,
    treefmt-nix,
    git-hooks,
  }: let
    py = harbor.lib.python;
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forSystem = system: let
      pkgs = py.mkPkgs {inherit system;};
      treefmtEval = treefmt-nix.lib.evalModule pkgs (import ./nix/treefmt.nix {inherit harbor;});
      hooks = import "${git-hooks}/nix" {
        nixpkgs =
          if system == "x86_64-darwin"
          then nixpkgs-darwin
          else nixpkgs;
        inherit system;
        isFlakes = true;
      };
      pre-commit-check = hooks.run {
        src = ./.;
        hooks = import ./nix/pre-commit.nix {
          inherit pkgs;
          treefmtWrapper = treefmtEval.config.build.wrapper;
        };
      };
    in {
      inherit treefmtEval pre-commit-check;
      default = py.mkUvDevShell {
        inherit pkgs;
        extraPackages = pre-commit-check.enabledPackages;
        shellHookSuffix = pre-commit-check.shellHook;
      };
    };
  in {
    devShells = nixpkgs.lib.genAttrs systems (system: {
      default = (forSystem system).default;
    });

    formatter = nixpkgs.lib.genAttrs systems (
      system: (forSystem system).treefmtEval.config.build.wrapper
    );

    checks = nixpkgs.lib.genAttrs systems (system: {
      formatting = (forSystem system).treefmtEval.config.build.check self;
    });
  };
}
