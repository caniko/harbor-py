{harbor-meta}: _: {
  imports = [
    harbor-meta.treefmtModules.nix
    harbor-meta.treefmtModules.toml
    ./treefmt/python.nix
  ];
  projectRootFile = "flake.nix";
  # Same policy as the harbor superproject root: templates and fixtures keep
  # their own bytes.
  settings.excludes = [
    "templates/**"
    "tests/fixtures/**"
    "checks/fixtures/**"
    ".github/workflows/*.yaml"
  ];
}
