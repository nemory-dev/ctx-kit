"""Installed hook isolation from the parent repository's Git environment."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class HookIndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-hook-index-test-")
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
        self.run_ctx("init", "--no-hook", "--no-backfill")
        self.context = self.project / "sample-context"
        self.log = self.context / "work-log/timeline.jsonl"
        self.git("init", "--quiet")
        (self.project / "app.txt").write_text("app baseline\n", encoding="utf-8")
        (self.project / "other.txt").write_text("other baseline\n", encoding="utf-8")
        self.parent_files = ["app.txt", "ctx.config.json", "ctx.sh", "other.txt"]
        self.git("add", "--", *self.parent_files)
        self.git("commit", "--quiet", "-m", "fixture")
        self.run_ctx("hook", "install")
        self.context_head = self.git("-C", str(self.context), "rev-parse", "HEAD").strip()
        (self.context / "backlog.md").write_text(
            "# Backlog\nPrivate context for the hook snapshot\n", encoding="utf-8"
        )

    def run_ctx(self, *args):
        result = subprocess.run(
            ["bash", str(self.script), *args], cwd=self.project, env=self.env,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, *args):
        result = subprocess.run(
            ["git", *args], cwd=self.project, env=self.env,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def assert_isolated_snapshot(self):
        self.assertEqual(
            self.git("ls-tree", "-r", "--name-only", "HEAD").splitlines(),
            self.parent_files,
        )
        entries = [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["files"], ["app.txt"])
        self.assertEqual(entries[0]["commit"], "pending")
        self.assertNotEqual(
            self.git("-C", str(self.context), "rev-parse", "HEAD").strip(),
            self.context_head,
        )
        self.assertIn(
            "Private context for the hook snapshot",
            self.git("-C", str(self.context), "show", "HEAD:backlog.md"),
        )
        saved_log = self.git("-C", str(self.context), "show", "HEAD:work-log/timeline.jsonl")
        self.assertEqual([json.loads(line) for line in saved_log.splitlines()], entries)
        self.git("fsck", "--no-reflogs", "--no-dangling")
        self.git("-C", str(self.context), "fsck", "--no-reflogs", "--no-dangling")

    def test_normal_commit_keeps_context_out_of_parent_repository(self):
        (self.project / "app.txt").write_text("app changed\n", encoding="utf-8")
        self.git("add", "app.txt")
        self.git("commit", "--quiet", "-m", "normal change")
        self.assertEqual(self.git("show", "HEAD:app.txt"), "app changed\n")
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")
        self.assert_isolated_snapshot()

    def test_only_commit_preserves_other_staged_changes_and_context_snapshot(self):
        (self.project / "app.txt").write_text("app selected\n", encoding="utf-8")
        (self.project / "other.txt").write_text("other staged\n", encoding="utf-8")
        self.git("add", "other.txt")
        other_blob = self.git("rev-parse", ":other.txt")

        self.git("commit", "--quiet", "--only", "-m", "selected change", "--", "app.txt")

        self.assertEqual(self.git("show", "HEAD:app.txt"), "app selected\n")
        self.assertEqual(self.git("show", "HEAD:other.txt"), "other baseline\n")
        self.assertEqual(self.git("show", ":other.txt"), "other staged\n")
        self.assertEqual(self.git("rev-parse", ":other.txt"), other_blob)
        self.assertEqual(self.git("diff", "--cached", "--name-only").splitlines(), ["other.txt"])
        self.assert_isolated_snapshot()

    def test_explicit_parent_git_directory_does_not_redirect_context_git(self):
        (self.project / "app.txt").write_text("app explicit repository\n", encoding="utf-8")
        self.git("add", "app.txt")
        self.git(
            "--git-dir", str(self.project / ".git"),
            "--work-tree", str(self.project),
            "commit", "--quiet", "-m", "explicit repository change",
        )
        self.assertEqual(self.git("show", "HEAD:app.txt"), "app explicit repository\n")
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")
        self.assert_isolated_snapshot()


if __name__ == "__main__":
    unittest.main()
