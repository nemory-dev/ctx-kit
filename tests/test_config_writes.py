"""Real-CLI regressions for atomic configuration updates and write failures."""

import copy
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest


REPO = Path(__file__).resolve().parents[1]
OPERATIONS = ("enable", "disable", "hook-install", "hook-uninstall")


class ConfigWriteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-config-write-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.env = dict(
            os.environ,
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="ctx-kit test",
            GIT_AUTHOR_EMAIL="test@example.invalid",
            GIT_COMMITTER_NAME="ctx-kit test",
            GIT_COMMITTER_EMAIL="test@example.invalid",
            PYTHONDONTWRITEBYTECODE="1",
        )

    def prepare(self, operation, scripts=False):
        self.project = self.base / (operation + ("-scripts" if scripts else "-root"))
        self.project.mkdir()
        self.script = self.project / ("scripts/ctx.sh" if scripts else "ctx.sh")
        self.script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / "ctx.sh", self.script)
        self.config = self.project / "ctx.config.json"
        self.context = self.project / "context's 한글 folder"
        self.context.mkdir()
        (self.context / "AGENT_RULES.md").write_text("# Existing rules\n", encoding="utf-8")
        document = {
            "source": self.context.name + "/AGENT_RULES.md",
            "agent_rules": [{"name": "Codex", "path": "AGENTS.md", "enabled": operation == "disable"}],
            "git_sync": {"enabled": False, "auto_log": False},
            "preserve": {"한글": "user's original setting", "values": [1, False, None]},
        }
        self.config.write_text(json.dumps(document, ensure_ascii=False, indent=2), encoding="utf-8")
        self.config.chmod(0o640)
        self.assert_success(self.command("git", "init", "--quiet"))
        self.arguments = {
            "enable": ("enable", "Codex"),
            "disable": ("disable", "Codex"),
            "hook-install": ("hook", "install"),
            "hook-uninstall": ("hook", "uninstall"),
        }[operation]
        if operation == "hook-uninstall":
            self.assert_success(self.run_ctx("hook", "install"))
        self.original = self.config.read_bytes()
        self.original_mode = stat.S_IMODE(self.config.stat().st_mode)
        self.expected = copy.deepcopy(json.loads(self.original))
        if operation in ("enable", "disable"):
            self.expected["agent_rules"][0]["enabled"] = operation == "enable"
        else:
            self.expected["git_sync"]["enabled"] = operation == "hook-install"

    def command(self, *args, env=None):
        return subprocess.run(
            list(args), cwd=self.project, env=env or self.env,
            text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=20,
        )

    def run_ctx(self, *args, env=None):
        return self.command("bash", str(self.script), *args, env=env)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def install_fault(self, stage):
        hooks = self.project / "python-hooks"
        hooks.mkdir()
        (hooks / "sitecustomize.py").write_text(textwrap.dedent('''\
            import builtins
            import io
            import os

            _target = os.environ["CTX_TEST_CONFIG_FILE"]
            _directory = os.path.dirname(_target)
            _fault = os.environ["CTX_TEST_CONFIG_FAULT"]
            _open = builtins.open
            _io_open = io.open
            _fdopen = os.fdopen
            _os_open = os.open
            _write = os.write
            _fsync = os.fsync
            _replace = os.replace
            _writer_inodes = set()

            def normalized(path):
                if isinstance(path, int):
                    return None
                try:
                    return os.path.abspath(os.fsdecode(path))
                except TypeError:
                    return None

            def config_or_staging(path):
                path = normalized(path)
                return path == _target or (path is not None
                    and os.path.dirname(path) == _directory
                    and os.path.basename(path).startswith(".ctx-write-"))

            def inode(fd):
                info = os.fstat(fd)
                return info.st_dev, info.st_ino

            def writing_fd(fd):
                return inode(fd) in _writer_inodes

            def failure(stage):
                raise OSError("injected config " + stage + " failure")

            class FaultStream:
                def __init__(self, stream):
                    self.stream = stream
                    self.flush_failed = False

                def __getattr__(self, name):
                    return getattr(self.stream, name)

                def __enter__(self):
                    self.stream.__enter__()
                    return self

                def __exit__(self, *args):
                    try:
                        if _fault == "flush":
                            self.flush()
                    finally:
                        self.stream.__exit__(*args)

                def write(self, value):
                    if _fault == "write":
                        self.stream.write(value[:7])
                        failure("write")
                    return self.stream.write(value)

                def flush(self):
                    if _fault == "flush" and not self.flush_failed:
                        self.flush_failed = True
                        failure("flush")
                    return self.stream.flush()

            def opening(opener, path, *args, **kwargs):
                stream = opener(path, *args, **kwargs)
                if isinstance(stream, FaultStream):
                    return stream
                mode = args[0] if args else kwargs.get("mode", "r")
                writing = (config_or_staging(path) and any(c in mode for c in "wax+"))
                writing = writing or (isinstance(path, int) and writing_fd(path))
                if writing:
                    _writer_inodes.add(inode(stream.fileno()))
                    return FaultStream(stream)
                return stream

            def fail_open(path, *args, **kwargs):
                return opening(_open, path, *args, **kwargs)

            def fail_io_open(path, *args, **kwargs):
                return opening(_io_open, path, *args, **kwargs)

            def fail_fdopen(fd, *args, **kwargs):
                return opening(_fdopen, fd, *args, **kwargs)

            def fail_os_open(path, flags, *args, **kwargs):
                fd = _os_open(path, flags, *args, **kwargs)
                if config_or_staging(path) and flags & (os.O_WRONLY | os.O_RDWR):
                    _writer_inodes.add(inode(fd))
                return fd

            def fail_write(fd, value):
                if _fault == "write" and writing_fd(fd):
                    _write(fd, value[:7])
                    failure("write")
                return _write(fd, value)

            def fail_fsync(fd):
                if _fault == "fsync" and writing_fd(fd):
                    failure("fsync")
                return _fsync(fd)

            def fail_replace(source, destination, *args, **kwargs):
                if _fault == "replace" and normalized(destination) == _target:
                    failure("replace")
                return _replace(source, destination, *args, **kwargs)

            builtins.open = fail_open
            io.open = fail_io_open
            os.fdopen = fail_fdopen
            os.open = fail_os_open
            os.write = fail_write
            os.fsync = fail_fsync
            os.replace = fail_replace
            '''), encoding="utf-8")
        env = dict(self.env)
        env["PYTHONPATH"] = str(hooks) + os.pathsep + env.get("PYTHONPATH", "")
        env["CTX_TEST_CONFIG_FILE"] = str(self.config)
        env["CTX_TEST_CONFIG_FAULT"] = stage
        return env

    def assert_failure_preserves_config(self, stage):
        env = self.install_fault(stage)
        result = self.run_ctx(*self.arguments, env=env)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("injected config " + stage + " failure", result.stderr)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), self.original_mode)
        self.assertEqual(list(self.project.glob(".ctx-write-*")), [])
        self.assertNotIn("Sync complete.", result.stdout)
        self.assertNotIn("Git sync hook setup complete!", result.stdout)
        self.assertNotIn("Disabled git_sync in ctx.config.json", result.stdout)
        self.assertNotIn("→ Codex enabled", result.stdout)
        self.assertNotIn("→ Codex disabled", result.stdout)

    def test_write_failure_preserves_existing_configuration_for_all_commands(self):
        for operation in OPERATIONS:
            with self.subTest(operation=operation):
                self.prepare(operation)
                self.assert_failure_preserves_config("write")

    def test_flush_failure_preserves_existing_configuration_for_all_commands(self):
        for operation in OPERATIONS:
            with self.subTest(operation=operation):
                self.prepare(operation)
                self.assert_failure_preserves_config("flush")

    def test_fsync_failure_preserves_existing_configuration_for_all_commands(self):
        for operation in OPERATIONS:
            with self.subTest(operation=operation):
                self.prepare(operation)
                self.assert_failure_preserves_config("fsync")

    def test_replacement_failure_preserves_existing_configuration_for_all_commands(self):
        for operation in OPERATIONS:
            with self.subTest(operation=operation):
                self.prepare(operation)
                self.assert_failure_preserves_config("replace")

    def test_success_replaces_configuration_atomically_and_preserves_other_values(self):
        for operation in OPERATIONS:
            with self.subTest(operation=operation):
                self.prepare(operation)
                with self.config.open("rb") as previous:
                    self.assert_success(self.run_ctx(*self.arguments))
                    self.assertEqual(previous.read(), self.original)
                self.assertEqual(json.loads(self.config.read_text(encoding="utf-8")), self.expected)
                self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), self.original_mode)
                self.assertEqual(list(self.project.glob(".ctx-write-*")), [])

    def test_success_supports_root_and_scripts_installations_with_quoted_unicode_paths(self):
        for scripts in (False, True):
            for operation in OPERATIONS:
                with self.subTest(operation=operation, scripts=scripts):
                    self.prepare(operation, scripts=scripts)
                    quoted = self.project.with_name(self.project.name + "'s 한글 space")
                    self.project.rename(quoted)
                    self.project = quoted
                    self.script = quoted / ("scripts/ctx.sh" if scripts else "ctx.sh")
                    self.config = quoted / "ctx.config.json"
                    self.assert_success(self.run_ctx(*self.arguments))
                    self.assertEqual(json.loads(self.config.read_text(encoding="utf-8")), self.expected)

    def test_symlink_configuration_is_refused_without_touching_link_or_target(self):
        for operation in OPERATIONS:
            with self.subTest(operation=operation):
                self.prepare(operation)
                target = self.project / "original-settings.json"
                self.config.rename(target)
                self.config.symlink_to(target.name)
                result = self.run_ctx(*self.arguments)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(result.stderr.strip())
                self.assertTrue(self.config.is_symlink())
                self.assertEqual(os.readlink(self.config), target.name)
                self.assertEqual(target.read_bytes(), self.original)
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), self.original_mode)
                self.assertEqual(list(self.project.glob(".ctx-write-*")), [])


if __name__ == "__main__":
    unittest.main()
