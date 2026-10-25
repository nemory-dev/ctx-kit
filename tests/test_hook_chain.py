"""Installed pre-commit hook chaining, preservation, and removal regressions."""

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
LEGACY_BLOCK = b"""
# --- BEGIN CTX-KIT GIT-SYNC HOOK ---
if [ -f "ctx.sh" ]; then
  bash ctx.sh _hook_run_pre_commit
elif [ -f "scripts/ctx.sh" ]; then
  bash scripts/ctx.sh _hook_run_pre_commit
fi
# --- END CTX-KIT GIT-SYNC HOOK ---
"""


class HookChainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-hook-chain-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve()
        self.script = self.project / "ctx.sh"
        shutil.copy2(REPO / "ctx.sh", self.script)
        shutil.copy2(REPO / "ctx.config.json", self.project / "ctx.config.json")
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
        self.git("init", "--quiet")
        self.assert_success(self.run_ctx("init", "--no-hook", "--no-backfill"))
        self.app = self.project / "app.txt"
        self.app.write_text("initial\n", encoding="utf-8")
        self.git("add", "app.txt")
        self.git("commit", "--quiet", "-m", "fixture")
        self.hook = self.project / ".git/hooks/pre-commit"
        self.backup = self.hook.with_name("pre-commit.ctx-kit-original")
        self.context = self.project / "sample-context"
        self.log = self.context / "work-log/timeline.jsonl"

    def run_command(self, *args):
        return subprocess.run(
            list(args), cwd=self.project, env=self.env,
            capture_output=True, text=True, timeout=30,
        )

    def run_ctx(self, *args):
        return self.run_command("bash", str(self.script), *args)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, *args):
        return self.assert_success(self.run_command("git", *args)).stdout.strip()

    def install(self):
        return self.assert_success(self.run_ctx("hook", "install"))

    def write_hook(self, body, mode=0o755):
        self.hook.write_bytes(body)
        self.hook.chmod(mode)

    def stage_app(self):
        self.app.write_text("changed\n", encoding="utf-8")
        self.git("add", "app.txt")

    def read_entries(self):
        self.assertTrue(self.log.is_file(), "The ctx hook did not record the commit attempt")
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_existing_last_command_failure_blocks_commit_before_ctx_runs(self):
        self.write_hook(b"#!/bin/sh\nprintf 'existing check failed\\n' >&2\nfalse\n")
        self.install()
        before_project = self.git("rev-parse", "HEAD")
        before_context = self.git("-C", str(self.context), "rev-parse", "HEAD")
        self.stage_app()
        result = self.run_command("git", "commit", "--quiet", "-m", "must reject")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("existing check failed", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), before_project)
        self.assertEqual(
            self.git("-C", str(self.context), "rev-parse", "HEAD"), before_context
        )
        self.assertFalse(self.log.exists())
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "app.txt")

    def test_existing_explicit_success_runs_ctx_after_original(self):
        self.write_hook(
            b"#!/bin/sh\nprintf 'original ran\\n' > original-hook-ran.txt\nexit 0\n"
        )
        self.install()
        self.stage_app()
        self.git("commit", "--quiet", "-m", "accepted")
        self.assertEqual(
            (self.project / "original-hook-ran.txt").read_text(), "original ran\n"
        )
        self.assertEqual(len(self.read_entries()), 1)
        self.assertEqual(self.read_entries()[0]["files"], ["app.txt"])
        self.assertEqual(self.git("show", "HEAD:app.txt"), "changed")

    def test_original_failure_code_arguments_and_working_directory_are_preserved(self):
        self.write_hook(
            b"#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > original-hook-args.txt\nexit 17\n"
        )
        self.install()
        result = self.run_command(str(self.hook), "one", "two words")
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertEqual(
            (self.project / "original-hook-args.txt").read_text().splitlines(),
            [str(self.project), "one", "two words"],
        )
        self.assertFalse(self.log.exists())

    def test_original_hook_uses_its_own_interpreter(self):
        self.write_hook(
            b"#!/usr/bin/env python3\n"
            b"from pathlib import Path\n"
            b"Path('python-hook-ran.txt').write_text('python hook\\n')\n"
        )
        self.install()
        self.stage_app()
        self.git("commit", "--quiet", "-m", "run original Python hook")
        self.assertEqual(
            (self.project / "python-hook-ran.txt").read_text(), "python hook\n"
        )
        self.assertEqual(len(self.read_entries()), 1)

    def test_repeated_install_keeps_one_original_and_runs_it_once(self):
        original = b"#!/bin/sh\nprintf 'run\\n' >> original-hook-runs.txt\n"
        self.write_hook(original)
        self.install()
        self.install()
        self.assertTrue(self.backup.is_file(), "The original hook was not preserved")
        self.assertEqual(self.backup.read_bytes(), original)
        self.stage_app()
        self.git("commit", "--quiet", "-m", "single hook invocation")
        self.assertEqual((self.project / "original-hook-runs.txt").read_text(), "run\n")
        self.assertEqual(len(self.read_entries()), 1)

    def test_uninstall_restores_original_bytes_and_mode(self):
        original = b"#!/bin/sh\n# Preserve whitespace exactly.  \n\nexit 0\n\n"
        self.write_hook(original, mode=0o751)
        self.install()
        self.assert_success(self.run_ctx("hook", "uninstall"))
        self.assertEqual(self.hook.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(self.hook.stat().st_mode), 0o751)
        self.assertFalse(self.backup.exists())
        config = json.loads((self.project / "ctx.config.json").read_text())
        self.assertFalse(config["git_sync"]["enabled"])

    def test_uninstall_removes_wrapper_when_there_was_no_original(self):
        self.install()
        self.assert_success(self.run_ctx("hook", "uninstall"))
        self.assertFalse(self.hook.exists())
        self.assertFalse(self.backup.exists())
        self.assertTrue((self.context / ".git").is_dir())

    def test_non_executable_original_is_not_activated(self):
        original = b"#!/bin/sh\nprintf 'must not run\\n' > inactive-hook-ran.txt\nexit 23\n"
        self.write_hook(original, mode=0o644)
        self.install()
        self.stage_app()
        self.git("commit", "--quiet", "-m", "ignore inactive original")
        self.assertFalse((self.project / "inactive-hook-ran.txt").exists())
        self.assertEqual(len(self.read_entries()), 1)
        self.assert_success(self.run_ctx("hook", "uninstall"))
        self.assertEqual(self.hook.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(self.hook.stat().st_mode), 0o644)

    def test_existing_backup_conflict_does_not_overwrite_either_hook(self):
        original = b"#!/bin/sh\nexit 0\n"
        saved = b"preserve a pre-existing backup\n"
        self.write_hook(original)
        self.backup.write_bytes(saved)
        result = self.run_ctx("hook", "install")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.hook.read_bytes(), original)
        self.assertEqual(self.backup.read_bytes(), saved)

    def test_cyclic_original_symlink_is_not_replaced_with_a_recursive_wrapper(self):
        self.hook.symlink_to("pre-commit")
        result = self.run_ctx("hook", "install")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.hook.is_symlink())
        self.assertEqual(os.readlink(self.hook), "pre-commit")
        self.assertFalse(os.path.lexists(self.backup))

    def test_case_insensitive_cyclic_original_symlink_is_refused(self):
        (self.project / "case-probe").touch()
        if not (self.project / "CASE-PROBE").exists():
            self.skipTest("Case-insensitive filesystem required")
        self.hook.symlink_to("PRE-COMMIT")
        result = self.run_ctx("hook", "install")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.hook.is_symlink())
        self.assertEqual(os.readlink(self.hook), "PRE-COMMIT")
        self.assertFalse(os.path.lexists(self.backup))

    def test_legacy_inline_hook_is_migrated_and_original_can_be_restored(self):
        original = b"#!/bin/sh\n# Existing project check\nfalse\n"
        self.write_hook(original + LEGACY_BLOCK, mode=0o751)
        self.install()
        self.stage_app()
        result = self.run_command("git", "commit", "--quiet", "-m", "must reject")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.log.exists())
        self.assert_success(self.run_ctx("hook", "uninstall"))
        self.assertEqual(self.hook.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(self.hook.stat().st_mode), 0o751)

    def test_relative_symlink_original_executes_and_is_restored_without_target_edits(self):
        target = self.hook.with_name("project-pre-commit")
        original = b"#!/bin/sh\nprintf 'linked hook ran\\n' > linked-hook-ran.txt\n"
        target.write_bytes(original)
        target.chmod(0o751)
        self.hook.symlink_to(target.name)
        self.install()
        self.assertTrue(self.backup.is_symlink())
        self.assertEqual(os.readlink(self.backup), target.name)
        self.stage_app()
        self.git("commit", "--quiet", "-m", "run linked original")
        self.assertEqual(
            (self.project / "linked-hook-ran.txt").read_text(), "linked hook ran\n"
        )
        self.assertEqual(len(self.read_entries()), 1)
        self.assert_success(self.run_ctx("hook", "uninstall"))
        self.assertTrue(self.hook.is_symlink())
        self.assertEqual(os.readlink(self.hook), target.name)
        self.assertFalse(os.path.lexists(self.backup))
        self.assertEqual(target.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o751)

    def test_missing_required_backup_blocks_runtime_install_and_uninstall(self):
        self.write_hook(b"#!/bin/sh\nexit 0\n")
        self.install()
        self.backup.unlink()
        wrapper = self.hook.read_bytes()
        config = (self.project / "ctx.config.json").read_bytes()
        self.stage_app()
        before = self.git("rev-parse", "HEAD")
        commit = self.run_command("git", "commit", "--quiet", "-m", "must reject")
        self.assertNotEqual(commit.returncode, 0, commit.stdout + commit.stderr)
        self.assertIn("missing", commit.stderr.lower())
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertFalse(self.log.exists())
        for action in ("install", "uninstall"):
            with self.subTest(action=action):
                result = self.run_ctx("hook", action)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.hook.read_bytes(), wrapper)
                self.assertFalse(self.backup.exists())
                self.assertEqual((self.project / "ctx.config.json").read_bytes(), config)

    def test_user_modified_wrapper_and_original_backup_are_preserved_on_refusal(self):
        original = b"#!/bin/sh\nexit 0\n"
        self.write_hook(original)
        self.install()
        modified = self.hook.read_bytes() + b"\n# Preserve this local customization.\n"
        self.hook.write_bytes(modified)
        config = (self.project / "ctx.config.json").read_bytes()
        for action in ("install", "uninstall"):
            with self.subTest(action=action):
                result = self.run_ctx("hook", action)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.hook.read_bytes(), modified)
                self.assertEqual(self.backup.read_bytes(), original)
                self.assertEqual((self.project / "ctx.config.json").read_bytes(), config)

    def test_failed_wrapper_replace_preserves_original_and_recovery_backup(self):
        original = b"#!/bin/sh\n# Preserve this original on installation failure.\nexit 0\n"
        self.write_hook(original, mode=0o751)
        faults = self.project / "hook-write-faults"
        faults.mkdir()
        (faults / "sitecustomize.py").write_text(
            "import os\n"
            "original_replace = os.replace\n"
            "def replace(source, destination, *args, **kwargs):\n"
            "    if os.path.abspath(destination) == os.environ.get('CTX_TEST_HOOK_FAIL_DEST'):\n"
            "        raise OSError('injected hook installation failure')\n"
            "    return original_replace(source, destination, *args, **kwargs)\n"
            "os.replace = replace\n",
            encoding="utf-8",
        )
        self.env["PYTHONPATH"] = str(faults)
        self.env["CTX_TEST_HOOK_FAIL_DEST"] = str(self.hook)
        result = self.run_ctx("hook", "install")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("injected hook installation failure", result.stderr)
        self.assertEqual(self.hook.read_bytes(), original)
        self.assertEqual(self.backup.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(self.hook.stat().st_mode), 0o751)
        self.assertEqual(stat.S_IMODE(self.backup.stat().st_mode), 0o751)

    def test_directory_at_hook_path_is_refused_without_touching_contents(self):
        self.hook.mkdir()
        keep = self.hook / "keep.txt"
        keep.write_text("preserve hook directory contents\n", encoding="utf-8")
        config = (self.project / "ctx.config.json").read_bytes()
        result = self.run_ctx("hook", "install")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.hook.is_dir())
        self.assertEqual(keep.read_text(), "preserve hook directory contents\n")
        self.assertFalse(self.backup.exists())
        self.assertEqual((self.project / "ctx.config.json").read_bytes(), config)

    def test_original_hook_receives_standard_input(self):
        self.write_hook(b"#!/bin/sh\ncat > original-hook-input.txt\nexit 0\n")
        self.install()
        self.stage_app()
        result = subprocess.run(
            [str(self.hook)], cwd=self.project, env=self.env,
            input="first line\nsecond line\n", capture_output=True, text=True, timeout=30,
        )
        self.assert_success(result)
        self.assertEqual(
            (self.project / "original-hook-input.txt").read_text(),
            "first line\nsecond line\n",
        )
        self.assertEqual(len(self.read_entries()), 1)


if __name__ == "__main__":
    unittest.main()
