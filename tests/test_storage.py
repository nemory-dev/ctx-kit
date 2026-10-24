"""Real-CLI regressions for archival and historical work-log persistence."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-storage-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve()
        self.script = self.project / "ctx.sh"
        shutil.copy2(REPO / "ctx.sh", self.script)
        (self.project / "ctx.config.json").write_text(
            json.dumps({"source": "context/AGENT_RULES.md"}), encoding="utf-8"
        )
        self.context = self.project / "context"
        self.logs = self.context / "work-log"
        self.logs.mkdir(parents=True)
        self.timeline = self.logs / "timeline.jsonl"
        self.plan = self.context / "MASTER_PLAN.md"
        self.plan.write_text("# Plan\n\n- [x] Keep completed work\n- [ ] Next task\n", encoding="utf-8")
        self.decisions = self.context / "decisions.md"
        self.decisions.write_text(
            "# Decisions\n\n## ADR-001 Retired\nStatus: Deprecated\nOld choice.\n\n"
            "## ADR-002 Current\nStatus: Accepted\nCurrent choice.\n",
            encoding="utf-8",
        )
        self.archive = self.context / "archive"
        self.env = os.environ.copy()
        self.env.update({
            "GIT_AUTHOR_NAME": "Storage Test", "GIT_AUTHOR_EMAIL": "storage@example.invalid",
            "GIT_COMMITTER_NAME": "Storage Test", "GIT_COMMITTER_EMAIL": "storage@example.invalid",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
        })

    def run_ctx(self, *args):
        return subprocess.run(
            ["bash", str(self.script), *args], cwd=self.project, env=self.env,
            capture_output=True, text=True, timeout=30,
        )

    def git(self, *args):
        result = subprocess.run(
            ["git", *args], cwd=self.project, env=self.env,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def initialize_git(self):
        self.git("init", "-q")
        (self.project / "source.txt").write_text("Initial work\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git("commit", "-q", "-m", "Initial work")

    def entry(self, title, entry_id="legacy-id", month="2024-01"):
        return {
            "id": entry_id, "createdAt": f"{month}-15T12:00:00+00:00",
            "title": title, "summary": title, "commit": "pending", "files": [],
        }

    def write_entries(self, path, entries):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "".join(json.dumps(entry, ensure_ascii=False) + "\n" for entry in entries),
            encoding="utf-8",
        )

    def read_entries(self, path):
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]

    def source_snapshot(self):
        return {path: path.read_bytes() for path in (self.plan, self.decisions, self.timeline) if path.exists()}

    def assert_sources_unchanged(self, before):
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content, str(path))

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Archiving complete!", result.stdout)

    def fail_replacement_of(self, path):
        # Fault injection reaches the real CLI and filesystem; only the final
        # rename is rejected, as can happen after a successful temporary write.
        hooks = self.project / "python-hooks"
        hooks.mkdir()
        (hooks / "sitecustomize.py").write_text(
            "import os\n"
            "_replace = os.replace\n"
            "def fail_replace(source, destination, *args, **kwargs):\n"
            "    if os.path.abspath(destination) == os.environ.get('CTX_TEST_FAIL_REPLACE'):\n"
            "        raise OSError('injected replacement failure')\n"
            "    return _replace(source, destination, *args, **kwargs)\n"
            "os.replace = fail_replace\n",
            encoding="utf-8",
        )
        self.env["PYTHONPATH"] = str(hooks) + os.pathsep + self.env.get("PYTHONPATH", "")
        self.env["CTX_TEST_FAIL_REPLACE"] = str(path)

    def test_task_archive_write_failure_keeps_completed_task(self):
        (self.archive / "completed-tasks.md").mkdir(parents=True)
        before = self.source_snapshot()
        self.assert_failed(self.run_ctx("archive", "--no-logs", "--no-decisions"))
        self.assert_sources_unchanged(before)

    def test_monthly_archive_write_failure_keeps_all_sources(self):
        self.write_entries(self.timeline, [self.entry("Old work")])
        (self.archive / "timeline-2024-01.jsonl").mkdir(parents=True)
        before = self.source_snapshot()
        self.assert_failed(self.run_ctx("archive", "--keep", "0"))
        self.assert_sources_unchanged(before)
        self.assertFalse((self.archive / "completed-tasks.md").exists())

    def test_digest_write_failure_keeps_all_sources(self):
        self.write_entries(self.timeline, [self.entry("Old work")])
        (self.logs / "timeline-digest.md").mkdir()
        before = self.source_snapshot()
        self.assert_failed(self.run_ctx("archive", "--keep", "0"))
        self.assert_sources_unchanged(before)
        self.assertFalse((self.archive / "timeline-2024-01.jsonl").exists())

    def test_digest_replacement_failure_keeps_sources_after_destination_persists(self):
        old = self.entry("Old work")
        self.write_entries(self.timeline, [old])
        before = self.source_snapshot()
        self.fail_replacement_of(self.logs / "timeline-digest.md")
        result = self.run_ctx("archive", "--keep", "0")
        self.assert_failed(result)
        self.assertIn("injected replacement failure", result.stderr)
        self.assert_sources_unchanged(before)
        self.assertEqual(self.read_entries(self.archive / "timeline-2024-01.jsonl"), [old])
        self.assertEqual(list(self.context.rglob(".ctx-write-*")), [])

    def test_timeline_replacement_failure_can_be_retried_without_losing_or_duplicating_logs(self):
        old = self.entry("Old work")
        self.write_entries(self.timeline, [old])
        before = self.timeline.read_bytes()
        self.fail_replacement_of(self.timeline)
        args = ("archive", "--keep", "0", "--no-tasks", "--no-decisions")
        result = self.run_ctx(*args)
        self.assert_failed(result)
        self.assertIn("injected replacement failure", result.stderr)
        self.assertEqual(self.timeline.read_bytes(), before)
        archived = self.archive / "timeline-2024-01.jsonl"
        self.assertEqual(self.read_entries(archived), [old])
        self.assertEqual(list(self.context.rglob(".ctx-write-*")), [])
        del self.env["CTX_TEST_FAIL_REPLACE"]
        result = self.run_ctx(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_entries(archived), [old])
        self.assertEqual(self.read_entries(self.timeline), [])

    def test_interrupted_task_archive_recovers_without_duplicating_tasks_or_adrs(self):
        old = self.entry("Old work")
        self.write_entries(self.timeline, [old])
        before = self.source_snapshot()
        journal = self.logs / ".ctx-archive-transaction.json"
        self.fail_replacement_of(self.plan)
        result = self.run_ctx("archive", "--keep", "0")
        self.assert_failed(result)
        self.assertIn("injected replacement failure", result.stderr)
        self.assert_sources_unchanged(before)
        self.assertTrue(journal.is_file())
        del self.env["CTX_TEST_FAIL_REPLACE"]
        result = self.run_ctx("archive", "--keep", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Keep completed work", self.plan.read_text(encoding="utf-8"))
        self.assertNotIn("ADR-001", self.decisions.read_text(encoding="utf-8"))
        self.assertEqual((self.archive / "completed-tasks.md").read_text(encoding="utf-8").count("Keep completed work"), 1)
        self.assertEqual((self.archive / "decisions-deprecated.md").read_text(encoding="utf-8").count("ADR-001"), 1)
        self.assertEqual(self.read_entries(self.archive / "timeline-2024-01.jsonl"), [old])
        self.assertEqual(self.read_entries(self.timeline), [])
        self.assertFalse(journal.exists())

    def test_malformed_hot_log_fails_before_any_archive_mutation(self):
        self.timeline.write_text(json.dumps(self.entry("Valid")) + "\n{broken\n", encoding="utf-8")
        before = self.source_snapshot()
        result = self.run_ctx("archive", "--keep", "0")
        self.assert_failed(result)
        self.assertIn("timeline.jsonl", result.stderr)
        self.assertIn("2", result.stderr)
        self.assert_sources_unchanged(before)
        self.assertFalse((self.archive / "completed-tasks.md").exists())

    def test_malformed_archive_log_fails_before_any_archive_mutation(self):
        self.write_entries(self.timeline, [self.entry("New work")])
        archived = self.archive / "timeline-2024-01.jsonl"
        archived.parent.mkdir()
        archived.write_text("{broken\n", encoding="utf-8")
        original_archive = archived.read_bytes()
        before = self.source_snapshot()
        self.assert_failed(self.run_ctx("archive", "--keep", "0"))
        self.assert_sources_unchanged(before)
        self.assertEqual(archived.read_bytes(), original_archive)

    def test_malformed_other_archive_month_prevents_late_digest_loss(self):
        self.write_entries(self.timeline, [self.entry("New work")])
        broken = self.archive / "timeline-2023-12.jsonl"
        broken.parent.mkdir()
        broken.write_text("[]\n", encoding="utf-8")
        before = self.source_snapshot()
        self.assert_failed(self.run_ctx("archive", "--keep", "0"))
        self.assert_sources_unchanged(before)
        self.assertEqual(broken.read_text(encoding="utf-8"), "[]\n")
        self.assertFalse((self.archive / "timeline-2024-01.jsonl").exists())

    def test_legacy_id_collisions_survive_multiple_archive_batches(self):
        first = self.entry("First work")
        second = self.entry("Different work with the same old ID")
        self.write_entries(self.timeline, [first, second])
        result = self.run_ctx("archive", "--keep", "0", "--no-tasks", "--no-decisions")
        self.assertEqual(result.returncode, 0, result.stderr)
        archived = self.archive / "timeline-2024-01.jsonl"
        self.assertEqual(self.read_entries(archived), [first, second])
        third = self.entry("Another distinct work unit")
        # With no pending transaction this is a new batch, even when an entire
        # legacy record is identical to a record from a previous batch.
        self.write_entries(self.timeline, [second, third])
        result = self.run_ctx("archive", "--keep", "0", "--no-tasks", "--no-decisions")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_entries(archived), [first, second, second, third])
        self.assertEqual(self.read_entries(self.timeline), [])

    def test_identical_legacy_rows_preserve_occurrences_within_archive_batch(self):
        entry = self.entry("Identical legacy work")
        self.write_entries(self.timeline, [entry, entry])
        result = self.run_ctx("archive", "--keep", "0", "--no-tasks", "--no-decisions")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_entries(self.archive / "timeline-2024-01.jsonl"), [entry, entry])
        self.assertEqual(self.read_entries(self.timeline), [])

    def test_identical_legacy_rows_across_keep_boundary_are_all_preserved(self):
        entry = self.entry("Identical legacy work")
        self.write_entries(self.timeline, [entry, entry])
        archived = self.archive / "timeline-2024-01.jsonl"
        for keep, remaining in (("1", [entry]), ("0", [])):
            result = self.run_ctx("archive", "--keep", keep, "--no-tasks", "--no-decisions")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.read_entries(self.timeline), remaining)
        self.assertEqual(self.read_entries(archived), [entry, entry])

    def test_identical_legacy_rows_new_batches_preserve_occurrence_count(self):
        entry = self.entry("Identical legacy work")
        archived = self.archive / "timeline-2024-01.jsonl"
        # Existing identical rows do not identify a retry without a journal.
        self.write_entries(archived, [entry])
        args = ("archive", "--keep", "0", "--no-tasks", "--no-decisions")
        for batch in range(1, 3):
            self.write_entries(self.timeline, [entry, entry])
            result = self.run_ctx(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.read_entries(archived), [entry] * (1 + batch * 2))
            self.assertEqual(self.read_entries(self.timeline), [])

    def test_identical_legacy_rows_interrupted_transaction_retry_does_not_duplicate(self):
        entry = self.entry("Identical legacy work")
        self.write_entries(self.timeline, [entry, entry])
        archived = self.archive / "timeline-2024-01.jsonl"
        journal = self.logs / ".ctx-archive-transaction.json"
        self.fail_replacement_of(self.timeline)
        args = ("archive", "--keep", "0", "--no-tasks", "--no-decisions")
        result = self.run_ctx(*args)
        self.assert_failed(result)
        self.assertEqual(self.read_entries(self.timeline), [entry, entry])
        self.assertEqual(self.read_entries(archived), [entry, entry])
        self.assertTrue(journal.is_file())
        del self.env["CTX_TEST_FAIL_REPLACE"]
        result = self.run_ctx(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_entries(archived), [entry, entry])
        self.assertEqual(self.read_entries(self.timeline), [])
        self.assertFalse(journal.exists())

    def test_invalid_keep_does_not_mutate_sources_or_create_archive(self):
        self.write_entries(self.timeline, [self.entry("Old work")])
        before = self.source_snapshot()
        for value in ("-1", "1.5", "no", ""):
            with self.subTest(value=value):
                self.assert_failed(self.run_ctx("archive", "--keep", value))
                self.assert_sources_unchanged(before)
                self.assertFalse(self.archive.exists())

    def test_missing_keep_argument_fails_without_mutation(self):
        before = self.source_snapshot()
        self.assert_failed(self.run_ctx("archive", "--keep"))
        self.assert_sources_unchanged(before)
        self.assertFalse(self.archive.exists())

    def test_normal_archive_preserves_active_content_and_is_idempotent(self):
        old = self.entry("Archived work")
        recent = self.entry("Current work", "new-id", "2024-02")
        self.write_entries(self.timeline, [old, recent])
        result = self.run_ctx("archive", "--keep", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Keep completed work", self.plan.read_text(encoding="utf-8"))
        self.assertIn("Next task", self.plan.read_text(encoding="utf-8"))
        self.assertIn("Keep completed work", (self.archive / "completed-tasks.md").read_text(encoding="utf-8"))
        self.assertNotIn("ADR-001", self.decisions.read_text(encoding="utf-8"))
        self.assertIn("ADR-002", self.decisions.read_text(encoding="utf-8"))
        self.assertIn("ADR-001", (self.archive / "decisions-deprecated.md").read_text(encoding="utf-8"))
        self.assertEqual(self.read_entries(self.timeline), [recent])
        self.assertEqual(self.read_entries(self.archive / "timeline-2024-01.jsonl"), [old])
        digest = self.logs / "timeline-digest.md"
        self.assertIn("Archived work", digest.read_text(encoding="utf-8"))
        before = {path: path.read_bytes() for path in self.context.rglob("*") if path.is_file() and path.name != ".ctx.lock"}
        result = self.run_ctx("archive", "--keep", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content, str(path))

    def test_backfill_malformed_input_is_reported_and_preserved(self):
        self.initialize_git()
        self.timeline.write_text(json.dumps(self.entry("Valid")) + "\n{broken\n", encoding="utf-8")
        before = self.timeline.read_bytes()
        result = self.run_ctx("backfill", "--all")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("timeline.jsonl", result.stderr)
        self.assertIn("2", result.stderr)
        self.assertEqual(self.timeline.read_bytes(), before)

    def test_backfill_rejects_nonobject_record_without_rewrite(self):
        self.initialize_git()
        self.timeline.write_text("null\n", encoding="utf-8")
        result = self.run_ctx("backfill")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.timeline.read_text(encoding="utf-8"), "null\n")

    def test_backfill_replacement_failure_preserves_existing_log_and_allows_retry(self):
        self.initialize_git()
        historic = self.entry("Existing work")
        self.write_entries(self.timeline, [historic])
        before = self.timeline.read_bytes()
        self.fail_replacement_of(self.timeline)
        result = self.run_ctx("backfill", "--all")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("injected replacement failure", result.stderr)
        self.assertEqual(self.timeline.read_bytes(), before)
        self.assertEqual(list(self.context.rglob(".ctx-write-*")), [])
        del self.env["CTX_TEST_FAIL_REPLACE"]
        result = self.run_ctx("backfill", "--all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.read_entries(self.timeline)), 2)
        self.assertIn(historic, self.read_entries(self.timeline))

    def test_backfill_preserves_existing_entries_and_is_idempotent(self):
        self.initialize_git()
        historic = self.entry("Existing work")
        self.write_entries(self.timeline, [historic])
        result = self.run_ctx("backfill", "--all")
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = self.read_entries(self.timeline)
        self.assertEqual(len(entries), 2)
        self.assertIn(historic, entries)
        self.assertEqual(sum(e.get("fullCommit") == self.git("rev-parse", "HEAD") for e in entries), 1)
        before = self.timeline.read_bytes()
        result = self.run_ctx("backfill", "--all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.timeline.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
