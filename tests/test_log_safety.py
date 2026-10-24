"""Work-log identity, write failure, and concurrent writer regressions."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class LogSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-log-test-")
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
        result = self.run_ctx("init", "--no-hook", "--no-backfill")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.context = self.project / "sample-context"
        self.log = self.context / "work-log/timeline.jsonl"
        self.log.parent.mkdir(exist_ok=True)

    def run_ctx(self, *args):
        return subprocess.run(
            ["bash", str(self.script), *args],
            cwd=self.project, env=self.env, capture_output=True, text=True,
            timeout=30,
        )

    def git(self, *args):
        result = subprocess.run(
            ["git", *args], cwd=self.project, env=self.env,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def freeze_clock(self):
        # Freeze only time in subprocesses; the CLI still performs real I/O.
        clock = self.project / "test-clock"
        clock.mkdir()
        (clock / "sitecustomize.py").write_text(
            "import datetime\n"
            "class FrozenDateTime(datetime.datetime):\n"
            "    @classmethod\n"
            "    def now(cls, tz=None):\n"
            "        return cls(2026, 10, 24, 12, 0, 0, tzinfo=tz)\n"
            "datetime.datetime = FrozenDateTime\n",
            encoding="utf-8",
        )
        self.env["PYTHONPATH"] = str(clock)

    def read_entries(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def interrupt_archive(self):
        result = self.run_ctx("log", "--summary", "before interruption")
        self.assertEqual(result.returncode, 0, result.stderr)
        hooks = self.project / "write-faults"
        hooks.mkdir()
        (hooks / "sitecustomize.py").write_text(
            "import os\n"
            "original = os.replace\n"
            "def replace(source, destination, *args, **kwargs):\n"
            "    if os.path.abspath(destination) == os.environ.get('CTX_TEST_FAIL_REPLACE'):\n"
            "        raise OSError('injected archive interruption')\n"
            "    return original(source, destination, *args, **kwargs)\n"
            "os.replace = replace\n",
            encoding="utf-8",
        )
        self.env["PYTHONPATH"] = str(hooks)
        self.env["CTX_TEST_FAIL_REPLACE"] = str(self.log)
        result = self.run_ctx("archive", "--keep", "0")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("injected archive interruption", result.stderr)
        del self.env["CTX_TEST_FAIL_REPLACE"]

    def test_pending_archive_is_recovered_before_the_next_log(self):
        self.interrupt_archive()
        journal = self.log.parent / ".ctx-archive-transaction.json"
        self.assertTrue(journal.is_file())
        result = self.run_ctx("log", "--summary", "after recovery")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(journal.exists())
        self.assertEqual([entry["summary"] for entry in self.read_entries()], ["after recovery"])
        archived = []
        for path in (self.context / "archive").glob("timeline-*.jsonl"):
            archived.extend(json.loads(line) for line in path.read_text().splitlines())
        self.assertEqual([entry["summary"] for entry in archived], ["before interruption"])

    def test_archive_recovery_preserves_unexpected_external_edits(self):
        self.interrupt_archive()
        with self.log.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"id": "external", "summary": "manual edit"}) + "\n")
        original = self.log.read_bytes()
        result = self.run_ctx("log", "--summary", "must wait for reconciliation")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_bytes(), original)
        self.assertIn("changed", result.stderr.lower())
        self.assertTrue((self.log.parent / ".ctx-archive-transaction.json").is_file())

    def test_archive_recovery_rejects_paths_outside_the_context(self):
        outside = self.project / "keep.txt"
        outside.write_text("keep original\n")
        journal = self.log.parent / ".ctx-archive-transaction.json"
        journal.write_text(json.dumps({"version": 1, "writes": [
            {"path": "../keep.txt", "before": None, "after": "overwrite"},
        ]}), encoding="utf-8")
        result = self.run_ctx("log", "--summary", "must not overwrite outside")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Unsafe archive recovery path", result.stderr)
        self.assertEqual(outside.read_text(), "keep original\n")
        self.assertTrue(journal.exists())
        self.assertFalse(self.log.exists())

    def test_work_unit_ids_are_unique_with_identical_time_and_commit(self):
        self.freeze_clock()
        for summary in ("first work unit", "second work unit"):
            result = self.run_ctx("log", "--summary", summary)
            self.assertEqual(result.returncode, 0, result.stderr)
        entries = self.read_entries()
        self.assertEqual(len({entry["id"] for entry in entries}), 2)
        self.assertEqual(entries[0]["createdAt"], entries[1]["createdAt"])

    def test_pre_commit_ids_are_unique_with_identical_time(self):
        self.freeze_clock()
        self.git("init", "--quiet")
        (self.project / "app.txt").write_text("staged content\n")
        self.git("add", "app.txt")
        for _ in range(2):
            result = self.run_ctx("_hook_run_pre_commit")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        entries = self.read_entries()
        self.assertEqual(len({entry["id"] for entry in entries}), 2)

    def test_log_preserves_corrupt_jsonl_without_appending(self):
        original = b'{"id":"broken","summary":"keep this original"\n'
        self.log.write_bytes(original)
        result = self.run_ctx("log", "--summary", "must not be appended")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_bytes(), original)
        self.assertIn("timeline.jsonl", result.stderr)
        self.assertIn("line 1", result.stderr)
        self.assertNotIn("Recorded work-log entry:", result.stdout)

    def test_valid_final_record_without_newline_remains_readable(self):
        original = {"id": "legacy", "summary": "existing entry"}
        self.log.write_text(json.dumps(original), encoding="utf-8")
        result = self.run_ctx("log", "--summary", "next entry")
        self.assertEqual(result.returncode, 0, result.stderr)
        readback = self.run_ctx("timeline", "--json")
        self.assertEqual(readback.returncode, 0, readback.stdout + readback.stderr)
        entries = self.read_entries()
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[0], original)
        self.assertEqual(entries[1]["summary"], "next entry")

    @unittest.skipUnless(os.name == "posix", "POSIX advisory lock check")
    def test_log_waits_for_an_existing_writer_lock(self):
        import fcntl

        lock_path = self.log.parent / ".ctx.lock"
        with lock_path.open("a+b") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            process = subprocess.Popen(
                ["bash", str(self.script), "log", "--summary", "after unlock"],
                cwd=self.project, env=self.env, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True,
            )
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.communicate(timeout=1)
                self.assertFalse(self.log.exists())
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                stdout, stderr = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, stdout + stderr)
        self.assertEqual(self.read_entries()[0]["summary"], "after unlock")

    def test_concurrent_log_and_archive_preserve_every_work_unit(self):
        def write(index):
            return self.run_ctx("log", "--summary", f"work unit {index}")

        with ThreadPoolExecutor(max_workers=6) as pool:
            pending = [pool.submit(write, index) for index in range(12)]
            pending += [pool.submit(self.run_ctx, "archive", "--keep", "2")
                        for _ in range(3)]
            for future in pending:
                result = future.result()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_ctx("archive", "--keep", "2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        entries = self.read_entries()
        for path in (self.context / "archive").glob("timeline-*.jsonl"):
            entries.extend(json.loads(line) for line in path.read_text().splitlines())
        self.assertEqual(len(entries), 12)
        self.assertEqual({entry["summary"] for entry in entries},
                         {f"work unit {index}" for index in range(12)})
        self.assertEqual(len({entry["id"] for entry in entries}), 12)

    def test_runtime_lock_is_not_committed_to_local_context_git(self):
        self.git("init", "--quiet")
        result = self.run_ctx("log", "--summary", "before hook install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.log.parent / ".ctx.lock").is_file())
        result = self.run_ctx("hook", "install")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        files = self.git("-C", str(self.context), "ls-files").splitlines()
        self.assertNotIn("work-log/.ctx.lock", files)
        self.assertIn("work-log/timeline.jsonl", files)

    def test_runtime_lock_does_not_mark_a_clean_project_dirty(self):
        self.git("init", "--quiet")
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
        commit = self.git("rev-parse", "--short", "HEAD").strip()
        result = self.run_ctx("log", "--summary", "document clean commit")
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = self.read_entries()[0]
        self.assertFalse(entry["dirty"])
        self.assertEqual(entry["commit"], commit)
        self.assertNotIn("sample-context/work-log/.ctx.lock", entry["files"])

    def test_modified_file_path_is_recorded_without_runtime_artifacts(self):
        self.git("init", "--quiet")
        (self.project / "app.txt").write_text("initial\n")
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
        (self.project / "app.txt").write_text("changed\n")
        result = self.run_ctx("log", "--summary", "update app")
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = self.read_entries()[0]
        self.assertTrue(entry["dirty"])
        self.assertEqual(entry["files"], ["app.txt"])

    def test_concurrent_archives_with_local_git_preserve_every_work_unit(self):
        self.git("init", "--quiet")
        result = self.run_ctx("hook", "install")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with ThreadPoolExecutor(max_workers=6) as pool:
            pending = []
            for index in range(8):
                pending.append(pool.submit(self.run_ctx, "log", "--summary", f"git work {index}"))
                pending.append(pool.submit(self.run_ctx, "archive", "--keep", "1"))
            for future in pending:
                result = future.result()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        entries = self.read_entries()
        for path in (self.context / "archive").glob("timeline-*.jsonl"):
            entries.extend(json.loads(line) for line in path.read_text().splitlines())
        self.assertEqual(len(entries), 8)
        self.assertEqual({entry["summary"] for entry in entries},
                         {f"git work {index}" for index in range(8)})
        files = self.git("-C", str(self.context), "ls-files").splitlines()
        self.assertNotIn("work-log/.ctx.lock", files)
        self.assertFalse(any(".ctx-write-" in name for name in files))


if __name__ == "__main__":
    unittest.main()
