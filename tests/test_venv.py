"""Exercise managed venvs with real CPython and uv, without network access."""

import os
import importlib.util
import multiprocessing
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest import mock


class VenvTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="harbor venv ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.venv = self.root / "environment with spaces"
        self.helper = Path(
            os.environ.get(
                "HARBOR_VENV_HELPER",
                Path(__file__).resolve().parents[1] / "lib/venv.py",
            )
        )
        self.python = sys._base_executable
        self.wrapper = self.root / "python-launcher"
        self.wrapper.write_text(
            f"#!{shutil.which('bash')}\n"
            'export __PYVENV_LAUNCHER__="$(realpath -s "$0")"\n'
            "export HARBOR_RUNTIME_PROBE=wrapped\n"
            f'exec "{self.python}" "$@"\n'
        )
        self.wrapper.chmod(0o755)

    def manage(self, operation="prepare", site=False, check=True):
        return subprocess.run(
            [
                self.python,
                str(self.helper),
                operation,
                "--venv",
                str(self.venv),
                "--launcher",
                str(self.wrapper),
                *(["--system-site-packages"] if site else []),
            ],
            check=check,
            capture_output=True,
            text=True,
        )

    def assert_runtime(self):
        subprocess.run(
            [
                str(self.venv / "bin/python"),
                "-c",
                "import os, sys, subprocess; "
                "assert sys.prefix == sys.argv[1]; "
                "assert sys.executable == sys.argv[1] + '/bin/python'; "
                "assert os.environ['HARBOR_RUNTIME_PROBE'] == 'wrapped'; "
                "assert '__PYVENV_LAUNCHER__' not in os.environ; "
                "subprocess.run([sys.executable, '-c', 'import sys; assert sys.prefix != sys.base_prefix'], check=True)",
                str(self.venv),
            ],
            check=True,
        )

    def test_fresh_venv_and_runtime_update_preserve_identity(self):
        self.manage(site=True)
        sentinel = self.venv / "keep-me"
        sentinel.touch()
        self.assert_runtime()
        self.manage(site=True)
        self.assertTrue(sentinel.exists())
        subprocess.run(
            ["bin/python", "-c", "import sys; assert sys.prefix != sys.base_prefix"],
            cwd=self.venv,
            check=True,
        )

    def test_uv_created_venv_is_adopted_without_executable_field(self):
        subprocess.run(
            ["uv", "venv", "--offline", "--python", self.python, str(self.venv)],
            check=True,
        )
        self.assertNotIn("executable =", (self.venv / "pyvenv.cfg").read_text())
        sentinel = self.venv / "keep-me"
        sentinel.touch()
        self.manage()
        self.assertTrue(sentinel.exists())
        self.assert_runtime()

    def test_site_policy_change_recreates_managed_venv(self):
        self.manage()
        (self.venv / "old-environment").touch()
        self.manage(site=True)
        self.assertFalse((self.venv / "old-environment").exists())
        self.assertIn(
            "include-system-site-packages = true",
            (self.venv / "pyvenv.cfg").read_text(),
        )

    def test_incompatible_unmanaged_environment_is_preserved(self):
        subprocess.run(
            [self.python, "-m", "venv", "--without-pip", str(self.venv)], check=True
        )
        sentinel = self.venv / "keep-me"
        sentinel.touch()
        result = self.manage(site=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(sentinel.exists())

    def test_failed_recreation_restores_previous_environment(self):
        self.manage()
        sentinel = self.venv / "keep-me"
        sentinel.touch()
        original = (self.venv / "pyvenv.cfg").read_bytes()
        spec = importlib.util.spec_from_file_location("harbor_venv", self.helper)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        with mock.patch.object(
            helper, "create", side_effect=OSError("creation failed")
        ):
            with self.assertRaisesRegex(OSError, "creation failed"):
                helper.prepare(self.venv, True)
        self.assertTrue(sentinel.exists())
        self.assertEqual((self.venv / "pyvenv.cfg").read_bytes(), original)
        self.assert_runtime()

    def test_concurrent_prepare_waits_for_failed_recreation_and_keeps_restored_venv(
        self,
    ):
        self.manage()
        sentinel = self.venv / "keep-me"
        sentinel.touch()
        original = (self.venv / "pyvenv.cfg").read_bytes()
        spec = importlib.util.spec_from_file_location("harbor_venv", self.helper)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        context = multiprocessing.get_context("fork")
        first_parent, first_child = context.Pipe()
        second_parent, second_child = context.Pipe()

        def failing_creator():
            def fail(path, site):
                first_child.send("creating")
                if not first_child.poll(10):
                    raise TimeoutError("recreation release missing")
                first_child.recv()
                path.mkdir(exist_ok=True)
                (path / "partial").touch()
                raise OSError("creation failed")

            helper.create = fail
            try:
                helper.prepare(self.venv, True)
            except OSError:
                first_child.send("restored")

        def concurrent_entry():
            second_child.send("attempting")
            helper.prepare(self.venv, False)
            helper.wrap(self.venv, self.wrapper, False)
            second_child.send("finished")

        first = context.Process(target=failing_creator)
        second = context.Process(target=concurrent_entry)
        first.start()
        try:
            self.assertTrue(first_parent.poll(5))
            self.assertEqual(first_parent.recv(), "creating")
            second.start()
            self.assertTrue(second_parent.poll(5))
            self.assertEqual(second_parent.recv(), "attempting")
            # The second entry must not adopt/create/wrap an environment while
            # the first entry still owns replacement and rollback.
            self.assertFalse(second_parent.poll(0.5))
        finally:
            first_parent.send("release")
            for child in (first, second):
                if child.pid is not None:
                    child.join(10)
                    if child.is_alive():
                        child.terminate()
                        child.join(5)
            for connection in (first_parent, first_child, second_parent, second_child):
                connection.close()
        self.assertEqual(first.exitcode, 0)
        self.assertEqual(second.exitcode, 0)
        self.assertTrue(sentinel.exists())
        self.assertFalse((self.venv / "partial").exists())
        self.assertEqual((self.venv / "pyvenv.cfg").read_bytes(), original)
        self.assert_runtime()

    def test_sync_run_and_shebang_keep_wrapper(self):
        self.manage()
        (self.root / "pyproject.toml").write_text(
            '[project]\nname="runtime-probe"\nversion="0.1.0"\ndependencies=[]\n'
            "[tool.uv]\npackage=false\n"
        )
        env = dict(os.environ, VIRTUAL_ENV=str(self.venv))
        subprocess.run(
            [
                "uv",
                "sync",
                "--active",
                "--offline",
                "--python-preference",
                "only-system",
            ],
            cwd=self.root,
            env=env,
            check=True,
        )
        self.manage("wrap")
        subprocess.run(
            [
                "uv",
                "run",
                "--active",
                "--no-sync",
                "python",
                "-c",
                "import os; assert os.environ['HARBOR_RUNTIME_PROBE'] == 'wrapped'",
            ],
            cwd=self.root,
            env=env,
            check=True,
        )
        script = self.venv / "bin/probe"
        # POSIX shebangs cannot express an interpreter path containing spaces;
        # uv uses a shell trampoline for that case.
        script.write_text(
            f"#!{shutil.which('bash')}\n'''exec' \""
            + str(self.venv / "bin/python")
            + '" "$0" "$@"\n\' \'\'\'\n'
            "import os\nassert os.environ['HARBOR_RUNTIME_PROBE'] == 'wrapped'\n"
        )
        script.chmod(0o755)
        subprocess.run([str(script)], check=True)


if __name__ == "__main__":
    unittest.main()
