_: {
  projectRootFile = "flake.nix";
  programs.alejandra.enable = true;
  programs.taplo.enable = true;
  programs.ruff-format.enable = true;
  # Same policy as the harbor superproject root: templates and fixtures keep
  # their own bytes.
  settings.excludes = ["templates/**" "tests/fixtures/**" "checks/fixtures/**"];
}
