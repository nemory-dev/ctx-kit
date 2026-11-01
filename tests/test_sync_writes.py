"""Real-CLI regressions for safe MASTER_PLAN date updates during sync."""

from datetime import date
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
BACKUPS = ("file", "symlink", "broken-symlink", "directory")


class SyncWriteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-sync-write-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")

    def prepare(self, name, scripts=False, content=None):
        self.project = self.base / (name + "'s 한글 space")
        self.script = self.project / ("scripts/ctx.sh" if scripts else "ctx.sh")
        self.script.parent.mkdir(parents=True)
        shutil.copy2(REPO / "ctx.sh", self.script)
        self.context = self.project / "context's 한글 folder"
        self.context.mkdir()
        self.source = self.context / "AGENT_RULES.md"
        self.source.write_text("# Shared rules\n", encoding="utf-8")
        config = {
            "source": self.context.name + "/AGENT_RULES.md",
            "agent_rules": [{"name": "Codex", "path": "AGENTS.md", "enabled": True}],
            "git_sync": {"enabled": False, "auto_log": False},
        }
        (self.project / "ctx.config.json").write_text(
            json.dumps(config, ensure_ascii=False), encoding="utf-8"
        )
        self.plan = self.context / "MASTER_PLAN.md"
        self.original = content if content is not None else (
            "# Master Plan\n> Last Updated: 2000-01-01\n\n사용자 계획\n"
            "> Last Updated: 2001-02-03\nKeep this last line"
        ).encode("utf-8")
        self.plan.write_bytes(self.original)
        self.plan.chmod(0o640)
        self.backup = self.context / "MASTER_PLAN.md.bak"
        # A file from another operation must survive our temporary-file cleanup.
        (self.context / ".ctx-write-user").write_bytes(b"Keep unrelated staging data\n")

    def prepare_backup(self, kind):
        if kind == "file":
            self.backup.write_bytes(b"Unique user backup\x00\xff\n")
            self.backup.chmod(0o600)
        elif kind == "symlink":
            target = self.context / "user-backup.md"
            target.write_bytes(b"Unique symlink target\n")
            target.chmod(0o640)
            self.backup.symlink_to(target.name)
        elif kind == "broken-symlink":
            self.backup.symlink_to("missing-user-backup.md")
        elif kind == "directory":
            self.backup.mkdir(mode=0o750)
            (self.backup / "user-backup.md").write_bytes(b"Unique directory backup\n")

    def snapshot(self):
        entries = {}
        for path in sorted(self.context.rglob("*")):
            info = path.lstat()
            content = os.readlink(path) if path.is_symlink() else (
                path.read_bytes() if path.is_file() else None
            )
            entries[str(path.relative_to(self.context))] = (
                info.st_ino, info.st_mode, content
            )
        return entries

    def run_ctx(self, env=None):
        return subprocess.run(
            ["/bin/bash", str(self.script), "sync"], cwd=self.base,
            env=env or self.env, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=20,
        )

    def install_fault(self, stage):
        hooks = self.project / "python-hooks"
        hooks.mkdir()
        (hooks / "sitecustomize.py").write_text(textwrap.dedent('''\
            import os
            import tempfile

            _target = os.environ["CTX_TEST_PLAN"]
            _directory = os.path.dirname(_target)
            _fault = os.environ["CTX_TEST_SYNC_FAULT"]
            _mkstemp = tempfile.mkstemp
            _fdopen = os.fdopen
            _chmod = os.chmod
            _fsync = os.fsync
            _replace = os.replace
            _descriptors = set()
            _temporaries = set()

            def failure(stage):
                raise OSError("injected sync " + stage + " failure")

            def mkstemp(*args, **kwargs):
                staging = os.path.abspath(kwargs.get("dir") or tempfile.gettempdir()) == _directory
                if staging and _fault == "create":
                    failure("create")
                descriptor, path = _mkstemp(*args, **kwargs)
                if staging:
                    _descriptors.add(descriptor)
                    _temporaries.add(path)
                return descriptor, path

            class FaultStream:
                def __init__(self, stream):
                    self.stream = stream

                def __getattr__(self, name):
                    return getattr(self.stream, name)

                def __enter__(self):
                    self.stream.__enter__()
                    return self

                def __exit__(self, *args):
                    return self.stream.__exit__(*args)

                def write(self, value):
                    if _fault == "write":
                        self.stream.write(value[:7])
                        failure("write")
                    return self.stream.write(value)

                def flush(self):
                    if _fault == "flush":
                        failure("flush")
                    return self.stream.flush()

            def fdopen(descriptor, *args, **kwargs):
                stream = _fdopen(descriptor, *args, **kwargs)
                return FaultStream(stream) if descriptor in _descriptors else stream

            def chmod(path, *args, **kwargs):
                if _fault == "chmod" and path in _temporaries:
                    failure("chmod")
                return _chmod(path, *args, **kwargs)

            def fsync(descriptor):
                if _fault == "fsync" and descriptor in _descriptors:
                    failure("fsync")
                return _fsync(descriptor)

            def replace(source, destination, *args, **kwargs):
                if _fault == "replace" and os.path.abspath(destination) == _target:
                    failure("replace")
                return _replace(source, destination, *args, **kwargs)

            tempfile.mkstemp = mkstemp
            os.fdopen = fdopen
            os.chmod = chmod
            os.fsync = fsync
            os.replace = replace
            '''), encoding="utf-8")
        env = dict(self.env)
        env["PYTHONPATH"] = str(hooks) + os.pathsep + env.get("PYTHONPATH", "")
        env["CTX_TEST_PLAN"] = str(self.plan)
        env["CTX_TEST_SYNC_FAULT"] = stage
        return env

    def assert_failure_preserves_plan(self, stage):
        for kind in BACKUPS:
            with self.subTest(backup=kind):
                self.prepare(stage + "-" + kind)
                self.prepare_backup(kind)
                before = self.snapshot()

                result = self.run_ctx(env=self.install_fault(stage))

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("injected sync " + stage + " failure", result.stderr)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse((self.project / "AGENTS.md").is_symlink())
                self.assertNotIn("MASTER_PLAN.md Last Updated →", result.stdout)
                self.assertNotIn("Sync complete.", result.stdout)

    def test_sync_preserves_existing_backup_entries(self):
        for kind in BACKUPS:
            with self.subTest(backup=kind):
                self.prepare(kind)
                self.prepare_backup(kind)
                before = self.snapshot()
                with self.plan.open("rb") as previous:
                    result = self.run_ctx()
                    previous_content = previous.read()

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(previous_content, self.original)
                self.assertEqual(stat.S_IMODE(self.plan.stat().st_mode), 0o640)
                after = self.snapshot()
                del before["MASTER_PLAN.md"]
                del after["MASTER_PLAN.md"]
                self.assertEqual(after, before)
                expected = self.original.replace(b"2000-01-01", date.today().isoformat().encode("ascii"))
                expected = expected.replace(b"2001-02-03", date.today().isoformat().encode("ascii"))
                self.assertEqual(self.plan.read_bytes(), expected)
                self.assertEqual((self.project / "AGENTS.md").resolve(), self.source)

    def test_temporary_creation_failure_preserves_plan_and_backups(self):
        self.assert_failure_preserves_plan("create")

    def test_partial_write_failure_preserves_plan_and_backups(self):
        self.assert_failure_preserves_plan("write")

    def test_flush_failure_preserves_plan_and_backups(self):
        self.assert_failure_preserves_plan("flush")

    def test_permission_copy_failure_preserves_plan_and_backups(self):
        self.assert_failure_preserves_plan("chmod")

    def test_fsync_failure_preserves_plan_and_backups(self):
        self.assert_failure_preserves_plan("fsync")

    def test_replacement_failure_preserves_plan_and_backups(self):
        self.assert_failure_preserves_plan("replace")

    def test_root_and_scripts_installations_preserve_content_and_permissions(self):
        for scripts in (False, True):
            with self.subTest(scripts=scripts):
                self.prepare("paths-" + str(scripts), scripts=scripts)
                self.assertEqual(self.run_ctx().returncode, 0)
                self.assertEqual(stat.S_IMODE(self.plan.stat().st_mode), 0o640)
                self.assertIn(date.today().isoformat().encode("ascii"), self.plan.read_bytes())
                self.assertFalse(self.backup.exists())
                self.assertEqual([p.name for p in self.context.glob(".ctx-write-*")], [".ctx-write-user"])

    def test_unrelated_content_and_line_endings_are_preserved(self):
        for index, original in enumerate((b"", b"# No date\r\nKeep bytes\xff\n", b"# Plan\r\n> Last Updated: old\nEnd\r\n")):
            with self.subTest(content=original):
                self.prepare("content-" + str(index), content=original)
                result = self.run_ctx()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                expected = original.replace(b"> Last Updated: old", b"> Last Updated: " + date.today().isoformat().encode("ascii"))
                self.assertEqual(self.plan.read_bytes(), expected)

    def test_symlink_plan_is_refused_without_changing_link_or_target(self):
        for broken in (False, True):
            with self.subTest(broken=broken):
                self.prepare("plan-symlink-" + str(broken))
                target = self.context / "user-plan.md"
                self.plan.rename(target)
                self.plan.symlink_to("missing-plan.md" if broken else target.name)
                self.prepare_backup("file")
                before = self.snapshot()

                result = self.run_ctx()

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(result.stderr.strip())
                self.assertEqual(self.snapshot(), before)
                self.assertFalse((self.project / "AGENTS.md").is_symlink())

    def test_missing_plan_does_not_prevent_link_sync(self):
        self.prepare("missing-plan")
        self.plan.unlink()
        self.prepare_backup("file")
        before = self.snapshot()

        result = self.run_ctx()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual((self.project / "AGENTS.md").resolve(), self.source)


if __name__ == "__main__":
    unittest.main()
