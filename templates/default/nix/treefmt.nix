{harbor}: {...}: {
  imports = [
    harbor.treefmtModules.core-nix
    harbor.treefmtModules.core-toml
    harbor.treefmtModules.python-python
  ];
  projectRootFile = "flake.nix";
}
