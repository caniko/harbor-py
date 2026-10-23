{
  self,
  harbor,
  pkgs,
  system,
  nixpkgs,
  nixpkgs-darwin,
  treefmt-nix,
  git-hooks,
  meta,
  harborRoot,
}: let
  python = pkgs.python313;
  fixture = ../templates/default;
  templateFlake = builtins.readFile (fixture + "/flake.nix");
  templateSimit = builtins.fromTOML (builtins.readFile (fixture + "/simit.toml"));
  templatePyproject = builtins.fromTOML (builtins.readFile (fixture + "/pyproject.toml"));
  templateTreefmt = (treefmt-nix.lib.evalModule pkgs (import (fixture + "/nix/treefmt.nix") {harbor = harborRoot;})).config;
  languageTreefmt = (treefmt-nix.lib.evalModule pkgs {imports = [self.treefmtModules.python];}).config;
  templateHooks = builtins.readFile (fixture + "/nix/pre-commit.nix");
  ffmpeg = harbor.mkFfmpegCompat {inherit pkgs;};

  pythonSet = harbor.mkUvPythonSet {
    inherit pkgs python;
    workspaceRoot = fixture;
    dependencies = {
      minimal = [];
    };
    pyprojectOverrides = final: prev: {
      minimal = prev.minimal.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [])
          ++ [
            final.hatchling
          ];
      });
    };
  };

  minimalEnv = harbor.mkUvVirtualEnv {
    inherit pkgs python;
    name = "minimal-env";
    workspaceRoot = fixture;
    dependencies = {
      minimal = [];
    };
    pyprojectOverrides = final: prev: {
      minimal = prev.minimal.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [])
          ++ [
            final.hatchling
          ];
      });
    };
  };

  genericPackage = harbor.mkUvPackage {
    inherit pkgs python;
    name = "minimal-package";
    workspaceRoot = fixture;
    dependencies = {
      minimal = [];
    };
    pyprojectOverrides = final: prev: {
      minimal = prev.minimal.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [])
          ++ [
            final.hatchling
          ];
      });
    };
  };

  helper = harbor.mkUvHelper {
    inherit pkgs;
    name = "harbor-py-uv-helper-check";
    command = "--version";
  };

  validationPython = harbor.mkPythonEnv {
    inherit pkgs;
    packages = ps: [ps.pyyaml];
  };

  validationPackage = harbor.mkPythonApplicationPackage {
    inherit pkgs;
    name = "harbor-py-python-app";
    environment = validationPython;
    scripts = ["python3"];
  };

  shell = harbor.mkUvDevShell {
    inherit pkgs python;
    uvExtra = "dev";
    basePackages = [helper];
    autoSync = false;
  };

  shellWithoutSelections = harbor.mkUvDevShell {
    inherit pkgs python;
    uvExtra = null;
    devGroup = null;
    autoSync = false;
    opencodeLsp = {
      enable = false;
    };
  };

  ffmpegAbiCheck = harbor.mkFfmpegTorchCodecAbiCheck {
    inherit pkgs ffmpeg;
    name = "harbor-py-ffmpeg-torchcodec-abi-check";
  };

  torchcodecEnv = harbor.mkUvVirtualEnv {
    inherit pkgs python;
    name = "torchcodec-cpu-regression-env";
    workspaceRoot = ./fixtures/torchcodec-cpu;
    dependencies = {
      torch = [];
      torchcodec = [];
    };
    pyprojectOverrides = final: prev: {
      torchcodec =
        harbor.pythonOverrides.addTorchCodecFfmpegRuntime {
          inherit python ffmpeg;
        }
        final
        prev;
    };
  };
in
  assert templateSimit.flake
  == {
    scope = "full";
    mode = "custom";
    backend = "harbor-py";
    components = [
      "treefmt"
      "nix-flake-check"
    ];
  };
  # mkUvDevShell's default devGroup is synced with `--group dev`; uv rejects
  # an undefined group, which would fail every template shell entry.
  assert templatePyproject ? dependency-groups.dev;
  assert pkgs.lib.hasInfix "treefmt-nix.follows" templateFlake;
  assert pkgs.lib.hasInfix "git-hooks.follows" templateFlake;
  assert pkgs.lib.hasInfix "treefmtEval.config.build.check self" templateFlake;
  assert pkgs.lib.hasInfix "pre-commit-check.shellHook" templateFlake;
  assert templateTreefmt.programs.alejandra.enable;
  assert templateTreefmt.programs.taplo.enable;
  assert templateTreefmt.programs.ruff-format.enable;
  assert builtins.attrNames languageTreefmt.settings.formatter == ["ruff-format"];
  assert pkgs.lib.hasInfix "treefmt =" templateHooks;
  assert pkgs.lib.hasInfix "nix-flake-check" templateHooks;
    {
      exports-lib = pkgs.runCommand "harbor-py-exports-lib" {} ''
        test "${toString (builtins.elem "x86_64-linux" self.lib.packageSystems)}" = "1"
        mkdir -p $out
        echo ok > $out/result
      '';

      uv-python-set = pkgs.runCommand "harbor-py-uv-python-set" {} ''
        test -e ${pythonSet.minimal}
        test -x ${minimalEnv}/bin/python
        ${minimalEnv}/bin/python -c 'import minimal; print(minimal.VALUE)'
        test -x ${minimalEnv.passthru.pythonInterpreter}
        test -d ${minimalEnv.passthru.pythonSitePackages}
        test -x ${genericPackage}/bin/python
        ${genericPackage}/bin/python -c 'import minimal; print(minimal.VALUE)'
        mkdir -p $out
        echo ok > $out/result
      '';

      uv-dev-shell = pkgs.runCommand "harbor-py-uv-dev-shell" {} ''
        test -e ${shell}
        test -x ${helper}/bin/harbor-py-uv-helper-check
        test -e ${shellWithoutSelections}
        test "${builtins.toJSON (pkgs.lib.hasInfix "--extra" shellWithoutSelections.passthru.devShellSpec.shellHook)}" = "false"
        test "${builtins.toJSON (pkgs.lib.hasInfix "--group" shellWithoutSelections.passthru.devShellSpec.shellHook)}" = "false"
        # OpenCode's Python servers are on PATH for other editors, and only
        # when the OpenCode LSP profile is enabled.
        test "${builtins.toJSON (builtins.all (p: builtins.elem p shell.passthru.devShellSpec.packages) [pkgs.basedpyright pkgs.ruff])}" = "true"
        test "${builtins.toJSON (builtins.any (p: builtins.elem p shellWithoutSelections.passthru.devShellSpec.packages) [pkgs.basedpyright pkgs.ruff])}" = "false"
        mkdir -p $out
        echo ok > $out/result
      '';

      # OpenCode's rust server resolves from PATH (a composed toolchain's
      # rust-analyzer), not nixpkgs' rust-analyzer.
      opencode-rust-from-path =
        pkgs.runCommand "harbor-py-opencode-rust-from-path" {
          inherit (shell) nativeBuildInputs;
        } ''
          export HOME="$TMPDIR" XDG_CACHE_HOME="$TMPDIR" OPENCODE_CONFIG_CONTENT='{}'
          ${shell.passthru.devShellSpec.shellHook}
          test "$(${pkgs.jq}/bin/jq -c .lsp.rust.command <<<"$OPENCODE_CONFIG_CONTENT")" = '["rust-analyzer"]'
          ${pkgs.jq}/bin/jq -e '.lsp.basedpyright.command[0] | test("basedpyright-langserver$")' <<<"$OPENCODE_CONFIG_CONTENT" >/dev/null
          mkdir -p $out
          echo ok > $out/result
        '';

      managed-venv = import ./managed-venv.nix {inherit pkgs harbor;};

      template-default = meta.templateTests.mkCheck {
        inherit pkgs system;
        flakeNix = ../templates/default/flake.nix;
        inputs = {
          inherit nixpkgs nixpkgs-darwin treefmt-nix git-hooks;
          harbor = harborRoot;
        };
        requiredFiles = [
          "flake.nix"
          "pyproject.toml"
          "uv.lock"
          "src/minimal/__init__.py"
          "tests/test_minimal.py"
          "simit.toml"
          "nix/treefmt.nix"
          "nix/pre-commit.nix"
        ];
        requiredInputs = [
          "harbor"
          "treefmt-nix"
          "git-hooks"
        ];
        commands = [
          "uv"
          "python"
        ];
        env.UV_PYTHON_DOWNLOADS = "never";
        hookContains = ["uv sync"];
        inherit (meta) devShellTests;
      };

      python-env = pkgs.runCommand "harbor-py-python-env" {} ''
        test -x ${validationPython}/bin/python3
        ${validationPython}/bin/python3 -c 'import yaml; print(yaml.__version__)'
        test -x ${validationPackage}/bin/python3
        test -x ${validationPackage.passthru.pythonInterpreter}
        ${validationPackage.passthru.pythonInterpreter} -c 'import yaml'
        mkdir -p $out
        echo ok > $out/result
      '';

      ml-helpers = pkgs.runCommand "harbor-py-ml-helpers" {} ''
        test -x ${ffmpeg}/bin/ffmpeg
        test -e ${ffmpegAbiCheck}/result
        mkdir -p $out
        echo ok > $out/result
      '';
    }
    // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
      torchcodec-runtime = pkgs.runCommand "harbor-py-torchcodec-runtime" {} ''
        export HOME=$TMPDIR/home
        mkdir -p "$HOME" "$out"
        ${ffmpeg}/bin/ffmpeg -hide_banner -loglevel error \
          -f lavfi -i sine=frequency=440:sample_rate=8000:duration=0.1 sample.wav
        ${torchcodecEnv}/bin/python - <<'PY'
        import torch
        from torchcodec.decoders import AudioDecoder

        assert torch.version.cuda is None
        samples = AudioDecoder("sample.wav").get_all_samples()
        assert samples.sample_rate == 8000
        assert samples.data.shape[-1] == 800
        assert torch.isfinite(samples.data).all()
        assert samples.data.abs().sum() > 0
        PY
        echo ok > $out/result
      '';
    }
