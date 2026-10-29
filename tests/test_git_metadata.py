"""Real Git regressions for work-log paths, state, and failed metadata reads."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SPECIAL_NAMES = [
    "한글.kt", "space name.txt", " leading and trailing.txt ",
    "line\nbreak.txt", "tab\tname.txt", "carriage\rreturn.txt",
    'quote"name.txt', "back\\slash.txt", "comma,name.txt",
    "nested/untracked.txt", "__CTX_FILES__\nname.txt",
    "__CTX_COMMIT_START__\nname.txt",
]


class GitMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-git-metadata-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve()
        self.script = self.project / "ctx.sh"
        shutil.copy2(REPO / "ctx.sh", self.script)
        self.config = self.project / "ctx.config.json"
        self.config.write_text(json.dumps({
            "source": "context/AGENT_RULES.md", "agent_rules": [],
            "git_sync": {"enabled": False, "auto_log": True},
        }), encoding="utf-8")
        self.context = self.project / "context"
        self.context.mkdir()
        (self.context / "AGENT_RULES.md").write_text("# Private rules\n", encoding="utf-8")
        (self.project / ".gitignore").write_text("/context/\n/fault-bin/\n", encoding="utf-8")
        self.env = dict(
            os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="Metadata Test", GIT_AUTHOR_EMAIL="metadata@example.invalid",
            GIT_COMMITTER_NAME="Metadata Test", GIT_COMMITTER_EMAIL="metadata@example.invalid",
            PYTHONDONTWRITEBYTECODE="1",
        )

    @property
    def timeline(self):
        return self.context / "work-log/timeline.jsonl"

    def command(self, *args):
        return subprocess.run(
            list(args), cwd=self.project, env=self.env,
            capture_output=True, text=True, timeout=30,
        )

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, *args):
        return self.success(self.command("git", *args)).stdout.strip()

    def run_ctx(self, *args):
        return self.command("/bin/bash", str(self.script), *args)

    def write_names(self, names, content="content\n"):
        for name in names:
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    def initialize_git(self, names=()):
        self.git("init", "--quiet")
        self.write_names(["app.txt"] + list(names))
        self.git("add", "--", ".")
        self.git("commit", "--quiet", "-m", "Initial project")

    def entries(self):
        return [json.loads(line) for line in self.timeline.read_text(encoding="utf-8").splitlines()]

    def fail_git_command(self, command, unless=None):
        # Keep Git and filesystem operations real; reject one metadata command.
        binaries = self.project / "fault-bin"
        binaries.mkdir()
        (binaries / "sitecustomize.py").write_text(
            "import os, subprocess, sys\n"
            "original = subprocess.Popen\n"
            "class FailedGitQuery(original):\n"
            "    def __init__(self, args, *positional, **keywords):\n"
            "        if (isinstance(args, (list, tuple)) and args\n"
            "                and os.path.basename(args[0]) == 'git'\n"
            "                and " + repr(command) + " in args[1:]\n"
            "                and " + repr(unless) + " not in args[1:]):\n"
            "            args = [sys.executable, '-S', '-c',\n"
            "                    \"import sys; print('injected Git metadata failure', file=sys.stderr); sys.exit(128)\"]\n"
            "        super().__init__(args, *positional, **keywords)\n"
            "subprocess.Popen = FailedGitQuery\n", encoding="utf-8",
        )
        self.env["PYTHONPATH"] = str(binaries)

    def assert_failed_without_append(self, result, before):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("injected Git metadata failure", result.stderr)
        self.assertNotIn("Recorded work-log entry:", result.stdout)
        self.assertEqual(self.timeline.read_bytes(), before)

    def advance_head_before(self, command):
        self.initialize_git()
        original = self.git("rev-parse", "HEAD")
        self.git("commit", "--quiet", "--allow-empty", "-m", "Concurrent commit")
        newer = self.git("rev-parse", "HEAD")
        self.git("update-ref", "HEAD", original)
        binaries = self.project / "fault-bin"
        binaries.mkdir()
        (binaries / "sitecustomize.py").write_text(
            "import os, subprocess\n"
            "original = subprocess.Popen\n"
            "class ConcurrentHead(original):\n"
            "    def __init__(self, args, *positional, **keywords):\n"
            "        if (isinstance(args, (list, tuple)) and args\n"
            "                and os.path.basename(args[0]) == 'git'\n"
            "                and " + repr(command) + " in args[1:]):\n"
            "            subprocess.run(['git', '-C', " + repr(str(self.project)) + ",\n"
            "                            'update-ref', 'HEAD', " + repr(newer) + "], check=True)\n"
            "        super().__init__(args, *positional, **keywords)\n"
            "subprocess.Popen = ConcurrentHead\n", encoding="utf-8",
        )
        self.env["PYTHONPATH"] = str(binaries)
        return original

    def test_log_preserves_untracked_file_names_and_lists_nested_files(self):
        self.initialize_git()
        self.write_names(SPECIAL_NAMES)
        self.success(self.run_ctx("log", "--summary", "new files"))
        entry = self.entries()[0]
        self.assertTrue(entry["dirty"])
        self.assertEqual(entry["commit"], "uncommitted")
        self.assertCountEqual(entry["files"], SPECIAL_NAMES)

    def test_log_preserves_modified_file_names(self):
        self.initialize_git(SPECIAL_NAMES)
        self.write_names(SPECIAL_NAMES, "changed\n")
        self.success(self.run_ctx("log", "--summary", "modified files"))
        self.assertCountEqual(self.entries()[0]["files"], SPECIAL_NAMES)

    def test_log_records_rename_destination_as_a_path(self):
        self.initialize_git()
        destination = "renamed\t한글.kt"
        self.git("mv", "--", "app.txt", destination)
        self.success(self.run_ctx("log", "--summary", "rename app"))
        self.assertEqual(self.entries()[0]["files"], [destination])

    def test_log_preserves_file_names_from_an_explicit_commit(self):
        self.initialize_git()
        self.write_names(SPECIAL_NAMES)
        self.git("add", "--", *SPECIAL_NAMES)
        self.git("commit", "--quiet", "-m", "Add special names")
        self.success(self.run_ctx("log", "--summary", "document commit", "--commit", "HEAD"))
        self.assertFalse(self.entries()[0]["dirty"])
        self.assertCountEqual(self.entries()[0]["files"], SPECIAL_NAMES)

    def test_log_detects_untracked_changes_when_git_hides_them_by_default(self):
        self.initialize_git()
        self.git("config", "status.showUntrackedFiles", "no")
        self.write_names(["untracked.txt"])
        self.success(self.run_ctx("log", "--summary", "untracked work"))
        entry = self.entries()[0]
        self.assertTrue(entry["dirty"])
        self.assertEqual(entry["commit"], "uncommitted")
        self.assertEqual(entry["files"], ["untracked.txt"])

    def test_log_status_failure_preserves_existing_history(self):
        self.initialize_git()
        self.success(self.run_ctx("log", "--summary", "existing record"))
        before = self.timeline.read_bytes()
        self.fail_git_command("status")
        result = self.run_ctx("log", "--summary", "must not claim clean")
        self.assert_failed_without_append(result, before)

    def test_log_repository_probe_failure_preserves_existing_history(self):
        self.initialize_git()
        self.success(self.run_ctx("log", "--summary", "existing record"))
        before = self.timeline.read_bytes()
        self.write_names(["app.txt"], "changed\n")
        self.fail_git_command("rev-parse")
        result = self.run_ctx("log", "--summary", "must not skip Git status")
        self.assert_failed_without_append(result, before)

    def test_log_broken_git_directory_is_not_treated_as_standalone(self):
        self.initialize_git()
        self.success(self.run_ctx("log", "--summary", "existing record"))
        before = self.timeline.read_bytes()
        (self.project / ".git/HEAD").write_text("invalid HEAD\n", encoding="utf-8")
        result = self.run_ctx("log", "--summary", "must not hide broken repository")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Recorded work-log entry:", result.stdout)
        self.assertEqual(self.timeline.read_bytes(), before)

    def test_log_short_commit_query_failure_preserves_existing_history(self):
        self.initialize_git()
        self.success(self.run_ctx("log", "--summary", "existing record"))
        before = self.timeline.read_bytes()
        self.fail_git_command("--short")
        result = self.run_ctx("log", "--summary", "must not lose clean commit")
        self.assert_failed_without_append(result, before)

    def test_log_explicit_commit_resolution_failure_preserves_existing_history(self):
        self.initialize_git()
        self.success(self.run_ctx("log", "--summary", "existing record"))
        before = self.timeline.read_bytes()
        self.fail_git_command("rev-parse", unless="--is-inside-work-tree")
        result = self.run_ctx("log", "--summary", "must resolve commit", "--commit", "HEAD")
        self.assert_failed_without_append(result, before)

    def test_log_invalid_explicit_commit_does_not_append_even_with_explicit_files(self):
        self.initialize_git()
        self.success(self.run_ctx("log", "--summary", "existing record"))
        before = self.timeline.read_bytes()
        result = self.run_ctx("log", "--summary", "invalid commit", "--commit", "not-a-ref", "--files", "app.txt")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Recorded work-log entry:", result.stdout)
        self.assertEqual(self.timeline.read_bytes(), before)

    def test_log_clean_git_repository_without_commits_remains_usable(self):
        self.git("init", "--quiet")
        (self.project / ".git/info/exclude").write_text("*\n", encoding="utf-8")
        self.success(self.run_ctx("log", "--summary", "clean unborn repository"))
        entry = self.entries()[0]
        self.assertFalse(entry["dirty"])
        self.assertEqual(entry["commit"], "uncommitted")
        self.assertEqual(entry["files"], [])

    def test_log_uses_one_resolved_commit_when_head_changes_before_abbreviation(self):
        original = self.advance_head_before("--short")
        self.success(self.run_ctx("log", "--summary", "snapshot original commit"))
        entry = self.entries()[0]
        self.assertEqual(entry["fullCommit"], original)
        self.assertTrue(original.startswith(entry["commit"]))
        self.assertCountEqual(entry["files"], [".gitignore", "app.txt", "ctx.config.json", "ctx.sh"])

    def test_log_uses_resolved_explicit_commit_when_head_changes_before_file_query(self):
        original = self.advance_head_before("show")
        self.success(self.run_ctx("log", "--summary", "snapshot HEAD", "--commit", "HEAD"))
        entry = self.entries()[0]
        self.assertEqual(entry["fullCommit"], original)
        self.assertCountEqual(entry["files"], [".gitignore", "app.txt", "ctx.config.json", "ctx.sh"])

    def test_log_commit_file_query_failure_preserves_existing_history(self):
        self.initialize_git()
        self.success(self.run_ctx("log", "--summary", "existing record"))
        before = self.timeline.read_bytes()
        self.fail_git_command("show")
        result = self.run_ctx("log", "--summary", "must not lose paths", "--commit", "HEAD")
        self.assert_failed_without_append(result, before)

    def test_log_without_a_git_repository_remains_usable(self):
        self.success(self.run_ctx("log", "--summary", "standalone work"))
        entry = self.entries()[0]
        self.assertEqual(entry["commit"], "uncommitted")
        self.assertEqual(entry["files"], [])

    def test_log_in_a_git_repository_without_commits_records_new_files(self):
        self.git("init", "--quiet")
        self.success(self.run_ctx("log", "--summary", "before first commit"))
        entry = self.entries()[0]
        self.assertTrue(entry["dirty"])
        self.assertEqual(entry["commit"], "uncommitted")
        self.assertCountEqual(entry["files"], [".gitignore", "ctx.sh", "ctx.config.json"])

    def test_backfill_preserves_file_names(self):
        self.initialize_git()
        self.write_names(SPECIAL_NAMES)
        self.git("add", "--", *SPECIAL_NAMES)
        self.git("commit", "--quiet", "-m", "Add special names")
        commit = self.git("rev-parse", "HEAD")
        self.success(self.run_ctx("backfill", "--all"))
        entry = next(entry for entry in self.entries() if entry["fullCommit"] == commit)
        self.assertCountEqual(entry["files"], SPECIAL_NAMES)

    def test_backfill_keeps_message_markers_separate_from_paths_and_commits(self):
        self.initialize_git()
        message = "Literal markers\n\n__CTX_FILES__\nDetails\n__CTX_COMMIT_START__\nMore details"
        self.git("commit", "--quiet", "--allow-empty", "-m", message)
        commit = self.git("rev-parse", "HEAD")
        self.success(self.run_ctx("backfill", "--all"))
        entries = self.entries()
        self.assertEqual(len(entries), 2)
        entry = next(entry for entry in entries if entry["fullCommit"] == commit)
        self.assertEqual(entry["summary"], message)
        self.assertEqual(entry["files"], [])

    def test_backfill_keeps_empty_and_renamed_commit_boundaries(self):
        self.initialize_git()
        destination = "\nrenamed\r한글.kt"
        self.git("mv", "--", "app.txt", destination)
        self.git("commit", "--quiet", "-m", "Rename app")
        rename = self.git("rev-parse", "HEAD")
        self.git("commit", "--quiet", "--allow-empty", "-m", "Empty change")
        empty = self.git("rev-parse", "HEAD")
        self.success(self.run_ctx("backfill", "--all"))
        entries = {entry["fullCommit"]: entry for entry in self.entries()}
        self.assertEqual(len(entries), 3)
        self.assertEqual(entries[rename]["files"], [destination])
        self.assertEqual(entries[empty]["files"], [])

    def test_installed_hook_preserves_staged_paths_and_records_pending_dirty_state(self):
        self.initialize_git()
        self.success(self.run_ctx("hook", "install"))
        self.write_names(SPECIAL_NAMES)
        self.git("add", "--", *SPECIAL_NAMES)
        self.git("commit", "--quiet", "-m", "Commit special paths")
        entry = self.entries()[0]
        self.assertCountEqual(entry["files"], SPECIAL_NAMES)
        self.assertEqual(entry["commit"], "pending")
        self.assertTrue(entry["dirty"])

    def test_hook_excludes_literal_context_paths_even_when_force_staged(self):
        self.initialize_git()
        self.context.rename(self.project / "ctx[ab]")
        self.context = self.project / "ctx[ab]"
        config = json.loads(self.config.read_text())
        config["source"] = "ctx[ab]/AGENT_RULES.md"
        self.config.write_text(json.dumps(config), encoding="utf-8")
        self.success(self.run_ctx("hook", "install"))
        private = self.context / "private.txt"
        private.write_text("private staged content\n", encoding="utf-8")
        # git add may skip nested repositories; explicitly stage the parent entry.
        blob = self.git("hash-object", "-w", "--", "ctx[ab]/private.txt")
        self.git("update-index", "--add", "--cacheinfo", "100644", blob, "ctx[ab]/private.txt")
        self.assertIn("ctx[ab]/private.txt", self.git("diff", "--cached", "--name-only", "-z").split("\0"))
        self.write_names(["app.txt"], "changed\n")
        self.git("add", "--", "app.txt")
        self.git("commit", "--quiet", "-m", "Mixed staged paths")
        self.assertEqual(self.entries()[0]["files"], ["app.txt"])
        self.assertNotIn("private.txt", self.entries()[0]["summary"])
        private.write_text("context only change\n", encoding="utf-8")
        blob = self.git("hash-object", "-w", "--", "ctx[ab]/private.txt")
        self.git("update-index", "--cacheinfo", "100644", blob, "ctx[ab]/private.txt")
        self.git("commit", "--quiet", "-m", "Context only")
        self.assertEqual(len(self.entries()), 1)

    def test_hook_git_query_failure_blocks_commit_without_appending_history(self):
        self.initialize_git()
        self.success(self.run_ctx("hook", "install"))
        self.success(self.run_ctx("log", "--summary", "existing record"))
        before = self.timeline.read_bytes()
        parent = self.git("rev-parse", "HEAD")
        self.write_names(["app.txt"], "changed\n")
        self.git("add", "--", "app.txt")
        self.fail_git_command("diff")
        result = self.command("git", "commit", "--quiet", "-m", "must fail")
        self.assert_failed_without_append(result, before)
        self.assertEqual(self.git("rev-parse", "HEAD"), parent)


if __name__ == "__main__":
    unittest.main()
