"""Source preservation, snapshot boundaries, and observed Git metadata."""

import json
import os
from pathlib import Path
import subprocess
import time
import unicodedata

from viewer_support import BaseViewCase


class ViewDataTests(BaseViewCase):
    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.read_view_model()

    def record(self, **values):
        result = {"id": "same", "createdAt": "2026-10-30T10:00:00+09:00",
                  "type": "work", "title": "A task", "summary": "A report",
                  "files": [], "commit": "pending", "branch": "main", "dirty": False}
        result.update(values)
        return result

    def init_git(self):
        self.git("init", "--quiet")
        self.git("config", "core.autocrlf", "false")
        (self.project / "app.txt").write_text("initial\n", encoding="utf-8")
        self.git("add", "--", ".")
        self.git("commit", "--quiet", "-m", "Initial")
        return self.git("rev-parse", "HEAD")

    def inject(self, code):
        directory = self.project / "fault-bin"
        directory.mkdir(exist_ok=True)
        (directory / "sitecustomize.py").write_text(code, encoding="utf-8")
        self.env["PYTHONPATH"] = str(directory)

    def test_collects_only_allowed_documents_and_all_archives(self):
        (self.context / "decisions.md").write_text("# Choice\n", encoding="utf-8")
        (self.context / "secret.txt").write_text("DO NOT READ", encoding="utf-8")
        for path in ("work-log/timeline.jsonl", "archive/timeline-2026-10.jsonl",
                     "archive/timeline-legacy.jsonl"):
            self.write_jsonl(path, [self.record()])
        before = self.source_snapshot()
        model = self.success(self.run_ctx("view"))
        self.assertEqual(len(model["entries"]), 3)
        self.assertEqual(len({entry["key"] for entry in model["entries"]}), 3)
        self.assertEqual([doc["key"] for doc in model["documents"]],
                         ["plan", "decisions", "backlog", "digest", "completed", "deprecated"])
        self.assertEqual(self.source_snapshot(), before)
        self.assertNotIn("DO NOT READ", self.output.read_text(encoding="utf-8"))

    def test_keeps_identical_occurrences_and_colliding_ids(self):
        entry = self.record()
        self.write_jsonl("work-log/timeline.jsonl", [entry, entry])
        self.write_jsonl("archive/timeline-old.jsonl", [entry])
        model = self.success(self.run_ctx("view"))
        self.assertEqual(len(model["entries"]), 3)
        self.assertTrue(all(item["record"] == entry for item in model["entries"]))

    def test_preserves_blank_line_numbers_and_unknown_fields(self):
        path = self.write_jsonl("work-log/timeline.jsonl", [])
        entry = self.record(type="future-kind", files=["a\nb\t한글.kt"], future={"ok": True})
        path.write_text("\n\n" + json.dumps(entry) + "\n", encoding="utf-8")
        item = self.success(self.run_ctx("view"))["entries"][0]
        self.assertEqual(item["sourceLine"], 3)
        self.assertEqual(item["sourcePath"], "work-log/timeline.jsonl")
        self.assertEqual(item["sourceKind"], "work_log")
        self.assertEqual(item["record"], entry)

    def test_record_text_preserves_large_integer_and_original_spacing(self):
        path = self.write_jsonl("work-log/timeline.jsonl", [])
        line = '  { "count" : 9007199254740993, "summary": "원문" }  '
        path.write_text(line + "\n", encoding="utf-8")
        item = self.success(self.run_ctx("view"))["entries"][0]
        self.assertEqual(item["recordText"], line)
        self.assertEqual(item["record"]["count"], 9007199254740993)

    def test_empty_context_and_missing_documents(self):
        (self.context / "MASTER_PLAN.md").unlink()
        model = self.success(self.run_ctx("view"))
        self.assertEqual(model["entries"], [])
        self.assertTrue(all(doc["status"] == "missing" and doc["text"] == ""
                            for doc in model["documents"]))

    def test_legacy_types_are_retained_with_warnings(self):
        entries = [{}, self.record(files="wrong", title=[], dirty="false", branch=2),
                   self.record(createdAt="2026-10-30T12:00:00")]
        self.write_jsonl("work-log/timeline.jsonl", entries)
        model = self.success(self.run_ctx("view"))
        self.assertEqual(len(model["entries"]), 3)
        self.assertTrue(model["warnings"])
        self.assertTrue(all(entry["timestampUtc"] is None for entry in model["entries"]
                            if entry["record"].get("createdAt") != "2026-10-30T10:00:00+09:00"))
        self.assertIn(entries[1], [item["record"] for item in model["entries"]])

    def test_utc_order_and_stable_ties(self):
        self.write_jsonl("work-log/timeline.jsonl", [self.record(createdAt="2026-10-30T02:00:00Z"),
                                                    self.record(createdAt="no date")])
        self.write_jsonl("archive/timeline-old.jsonl", [self.record(), self.record()])
        items = self.success(self.run_ctx("view"))["entries"]
        self.assertEqual(items[0]["sourcePath"], "work-log/timeline.jsonl")
        self.assertEqual([item["sourceLine"] for item in items[1:3]], [1, 2])
        self.assertIsNone(items[-1]["timestampUtc"])

    def test_corrupt_json_object_and_utf8_preserve_previous_output(self):
        self.success(self.run_ctx("view"))
        before = self.output.read_bytes()
        path = self.write_jsonl("work-log/timeline.jsonl", [])
        for content in (b'{}\n{"truncated":', b'{}\n[1]\n', b'{}\n\xff\n'):
            path.write_bytes(content)
            result = self.run_ctx("view")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("timeline.jsonl", result.stderr)
            self.assertIn("2", result.stderr)
            self.assertEqual(self.output.read_bytes(), before)

    def test_pending_archive_fails_without_recovery(self):
        self.success(self.run_ctx("view"))
        journal = self.context / "work-log/.ctx-archive-transaction.json"
        journal.write_text('{"invalid":true}', encoding="utf-8")
        before = self.source_snapshot()
        output = self.output.read_bytes()
        result = self.run_ctx("view")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive", result.stderr.lower())
        self.assertEqual(self.source_snapshot(), before)
        self.assertEqual(self.output.read_bytes(), output)

    def test_pending_archive_dangling_symlink_also_fails(self):
        (self.context / "work-log").mkdir()
        journal = self.context / "work-log/.ctx-archive-transaction.json"
        journal.symlink_to("missing")
        result = self.run_ctx("view")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(journal.is_symlink())

    def test_symlink_input_and_subdirectory_are_rejected(self):
        original = self.context / "MASTER_PLAN.md"
        original.unlink()
        target = self.project / "other.md"
        target.write_text("private", encoding="utf-8")
        original.symlink_to(target)
        result = self.run_ctx("view")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        original.unlink()
        (self.context / "archive").symlink_to(self.project, target_is_directory=True)
        self.assertNotEqual(self.run_ctx("view").returncode, 0)

    def test_fifo_input_is_rejected_without_blocking(self):
        os.mkfifo(str(self.context / "decisions.md"))
        started = time.monotonic()
        self.assertNotEqual(self.run_ctx("view").returncode, 0)
        self.assertLess(time.monotonic() - started, 5)

    def test_context_outside_project_is_rejected_before_writes(self):
        outside = self.project.parent / (self.project.name + "-outside")
        outside.mkdir()
        self.addCleanup(outside.rmdir)
        (self.project / "ctx.config.json").write_text(json.dumps({
            "source": "../" + outside.name + "/AGENT_RULES.md", "agent_rules": []}), encoding="utf-8")
        result = self.run_ctx("view")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_input_size_limit(self):
        (self.context / "decisions.md").write_bytes(b"x" * (20 * 1024 * 1024))
        self.assertNotEqual(self.run_ctx("view").returncode, 0)
        self.assertFalse(self.output.exists())

    def test_record_count_limit(self):
        self.write_jsonl("work-log/timeline.jsonl", [{}] * 20001)
        result = self.run_ctx("view")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("20000", result.stderr)

    def test_exact_input_byte_limit_is_allowed(self):
        config_bytes = len((self.project / "ctx.config.json").read_bytes())
        (self.context / "MASTER_PLAN.md").write_bytes(b"x" * (20 * 1024 * 1024 - config_bytes))
        model = self.success(self.run_ctx("view"))
        self.assertEqual(len(model["documents"][0]["text"]), 20 * 1024 * 1024 - config_bytes)

    def test_exact_record_limit_is_allowed_without_deduplication(self):
        self.write_jsonl("work-log/timeline.jsonl", [self.record()] * 20000)
        model = self.success(self.run_ctx("view"))
        self.assertEqual(len(model["entries"]), 20000)

    def test_retries_one_source_change_and_preserves_the_read_bytes(self):
        target = str(self.context / "MASTER_PLAN.md")
        self.inject("import os\noriginal = os.open\ncount = 0\n"
                    "def opening(path, *a, **kw):\n"
                    "    global count\n"
                    "    if os.fspath(path) == " + repr(target) + ":\n"
                    "        count += 1\n"
                    "        if count == 2:\n"
                    "            with open(path, 'w', encoding='utf-8') as f: f.write('# Changed once\\n')\n"
                    "    return original(path, *a, **kw)\nos.open = opening\n")
        model = self.success(self.run_ctx("view"))
        self.assertEqual(model["documents"][0]["text"], "# Changed once\n")
        self.assertIn("collectionStartedAt", model)
        self.assertIn("collectionFinishedAt", model)

    def test_repeated_source_changes_fail_and_preserve_output(self):
        self.success(self.run_ctx("view"))
        before = self.output.read_bytes()
        target = str(self.context / "MASTER_PLAN.md")
        self.inject("import os\noriginal = os.open\ncount = 0\n"
                    "def opening(path, *a, **kw):\n"
                    "    global count\n"
                    "    if os.fspath(path) == " + repr(target) + ":\n"
                    "        count += 1\n"
                    "        with open(path, 'w', encoding='utf-8') as f: f.write('# Change ' + str(count))\n"
                    "    return original(path, *a, **kw)\nos.open = opening\n")
        result = self.run_ctx("view")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed", result.stderr)
        self.assertEqual(self.output.read_bytes(), before)

    def test_archive_listing_change_is_recollected(self):
        archive = self.context / "archive"
        archive.mkdir()
        entry_text = json.dumps(self.record()) + "\n"
        self.inject("import os\noriginal = os.listdir\ncount = 0\n"
                    "def listing(path):\n"
                    "    global count\n"
                    "    if os.fspath(path) == " + repr(str(archive)) + ":\n"
                    "        count += 1\n"
                    "        if count == 3:\n"
                    "            with open(os.path.join(path, 'timeline-added.jsonl'), 'w', encoding='utf-8') as f: f.write(" + repr(entry_text) + ")\n"
                    "    return original(path)\nos.listdir = listing\n")
        model = self.success(self.run_ctx("view"))
        self.assertEqual(len(model["entries"]), 1)
        self.assertEqual(model["entries"][0]["sourcePath"], "archive/timeline-added.jsonl")

    def test_configuration_change_is_recollected(self):
        config = str(self.project / "ctx.config.json")
        updated = json.dumps({"source": "context/AGENT_RULES.md", "agent_rules": [], "note": "changed"})
        self.inject("import os\noriginal = os.open\ncount = 0\n"
                    "def opening(path, *a, **kw):\n"
                    "    global count\n"
                    "    if os.fspath(path) == " + repr(config) + ":\n"
                    "        count += 1\n"
                    "        if count == 2:\n"
                    "            with open(path, 'w', encoding='utf-8') as f: f.write(" + repr(updated) + ")\n"
                    "    return original(path, *a, **kw)\nos.open = opening\n")
        self.success(self.run_ctx("view"))
        self.assertEqual((self.project / "ctx.config.json").read_text(encoding="utf-8"), updated)

    def test_nonstandard_json_constants_are_rejected(self):
        path = self.write_jsonl("work-log/timeline.jsonl", [])
        for value in ("NaN", "Infinity", "-Infinity", "1e999"):
            path.write_text('{"legacy":' + value + '}\n', encoding="utf-8")
            result = self.run_ctx("view")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("timeline.jsonl", result.stderr)

    def test_context_lock_waits_for_writer(self):
        if os.name == "nt":
            self.skipTest("POSIX lock orchestration")
        import fcntl
        directory = self.context / "work-log"
        directory.mkdir()
        with (directory / ".ctx.lock").open("w+b") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            child = subprocess.Popen(["/bin/bash", str(self.script), "view"], cwd=self.project,
                                     env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                time.sleep(0.3)
                self.assertIsNone(child.poll(), "Viewer must wait for the shared writer lock")
                self.assertFalse(self.output.exists())
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                stdout, stderr = child.communicate(timeout=10)
                self.assertEqual(child.returncode, 0, repr(stdout + stderr))
            finally:
                if child.poll() is None:
                    child.kill()
                child.communicate()

    def test_git_without_repository(self):
        model = self.success(self.run_ctx("view"))
        self.assertEqual(model["git"]["status"], "not_repository")
        self.assertIsNone(model["git"]["head"])

    def test_git_unborn_and_detached(self):
        self.git("init", "--quiet")
        model = self.success(self.run_ctx("view"))
        self.assertEqual(model["git"]["status"], "available")
        self.assertIsNone(model["git"]["head"])
        self.assertTrue(model["git"]["branch"])
        self.git("add", "--", ".")
        self.git("commit", "--quiet", "-m", "Initial")
        self.git("checkout", "--detach", "--quiet")
        model = self.success(self.run_ctx("view"))
        self.assertIsNone(model["git"]["branch"])
        self.assertTrue(model["git"]["head"])

    def test_git_commit_reference_status_is_not_completion(self):
        head = self.init_git()
        blob = self.git("rev-parse", "HEAD:app.txt")
        entries = [self.record(commit=ref) for ref in
                   ("pending", "uncommitted", None, head, head[:9], "f" * 40, blob, "HEAD")]
        self.write_jsonl("work-log/timeline.jsonl", entries)
        model = self.success(self.run_ctx("view"))
        statuses = {str(item["record"]["commit"]): item["commitObjectStatus"]
                    for item in model["entries"]}
        self.assertEqual([statuses[key] for key in ("pending", "uncommitted", "None")],
                         ["not_recorded"] * 3)
        self.assertEqual(statuses[head], "verified")
        self.assertEqual(statuses[head[:9]], "verified")
        for ref in ("f" * 40, blob, "HEAD"):
            self.assertEqual(statuses[ref], "unavailable")

    def test_full_commit_fallback_preserves_explicit_commit_meaning(self):
        head = self.init_git()
        entries = [self.record(commit="", fullCommit=head),
                   self.record(commit=None, fullCommit=head),
                   self.record(commit="pending", fullCommit=head),
                   self.record(commit="uncommitted", fullCommit=head),
                   self.record(commit="f" * 40, fullCommit=head),
                   self.record(commit=head[:9], fullCommit="f" * 40)]
        missing = self.record(fullCommit=head)
        del missing["commit"]
        entries.insert(2, missing)
        self.write_jsonl("work-log/timeline.jsonl", entries)
        items = self.success(self.run_ctx("view"))["entries"]
        self.assertEqual([item["commitObjectRef"] for item in items],
                         [head, head, head, "pending", "uncommitted", "f" * 40, head[:9]])
        self.assertEqual([item["commitObjectStatus"] for item in items],
                         ["verified", "verified", "verified", "not_recorded", "not_recorded",
                          "unavailable", "verified"])
        self.assertEqual([item["record"] for item in items], entries)

    def test_git_preserves_special_paths_and_excludes_viewer_and_lock(self):
        self.init_git()
        names = ["space name.txt", "line\nbreak.txt", "tab\tname.txt", "comma,name.txt",
                 "한글.txt", unicodedata.normalize("NFD", "한글.txt")]
        # macOS may normalize these two path spellings to the same directory entry.
        for name in names:
            (self.project / name).write_text("new\n", encoding="utf-8")
        self.success(self.run_ctx("view"))
        model = self.success(self.run_ctx("view"))
        paths = [item["path"] for item in model["git"]["changes"]]
        actual_names = [item.name for item in self.project.iterdir()
                        if item.name.endswith(".txt") and item.name != "app.txt"]
        self.assertTrue(set(actual_names).issubset(paths))
        self.assertNotIn("context/generated/view.html", paths)
        self.assertNotIn("context/work-log/.ctx.lock", paths)

    def test_git_excludes_real_output_reached_through_parent_alias(self):
        self.init_git()
        (self.project / "reports").mkdir()
        (self.project / "alias").symlink_to("reports", target_is_directory=True)
        for _ in range(2):
            result = self.run_ctx("view", "--output", "alias/view.html")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        model = self.read_view_model(self.project / "reports/view.html")
        paths = [change["path"] for change in model["git"]["changes"]]
        self.assertNotIn("reports/view.html", paths)

    def test_git_rename_retains_both_paths(self):
        self.init_git()
        self.git("mv", "--", "app.txt", "renamed\t한글.txt")
        changes = self.success(self.run_ctx("view"))["git"]["changes"]
        rename = next(item for item in changes if item["status"].startswith("R"))
        self.assertEqual(rename["path"], "renamed\t한글.txt")
        self.assertEqual(rename["previousPath"], "app.txt")

    def test_git_failure_is_unknown_and_documents_survive(self):
        self.init_git()
        self.inject("import subprocess\noriginal = subprocess.run\n"
                    "def run(args, *a, **kw):\n"
                    "    if isinstance(args, list) and args and args[0] == 'git' and 'status' in args:\n"
                    "        return subprocess.CompletedProcess(args, 128, b'', b'injected failure')\n"
                    "    return original(args, *a, **kw)\nsubprocess.run = run\n")
        model = self.success(self.run_ctx("view"))
        self.assertEqual(model["git"]["status"], "unavailable")
        self.assertEqual(model["git"]["changes"], [])
        self.assertEqual(model["documents"][0]["status"], "present")

    def test_git_timeout_is_unknown(self):
        self.init_git()
        self.inject("import subprocess\noriginal = subprocess.run\n"
                    "def run(args, *a, **kw):\n"
                    "    if isinstance(args, list) and args and args[0] == 'git':\n"
                    "        raise subprocess.TimeoutExpired(args, kw.get('timeout'))\n"
                    "    return original(args, *a, **kw)\nsubprocess.run = run\n")
        model = self.success(self.run_ctx("view"))
        self.assertEqual(model["git"]["status"], "unavailable")
        self.assertTrue(any("timeout" in warning["message"].lower()
                            for warning in model["warnings"]))

    def test_missing_git_is_unknown(self):
        self.inject("import subprocess\noriginal = subprocess.run\n"
                    "def run(args, *a, **kw):\n"
                    "    if isinstance(args, list) and args and args[0] == 'git':\n"
                    "        raise FileNotFoundError('git unavailable')\n"
                    "    return original(args, *a, **kw)\nsubprocess.run = run\n")
        model = self.success(self.run_ctx("view"))
        self.assertEqual(model["git"]["status"], "unavailable")
        self.assertTrue(any("git unavailable" in warning["message"] for warning in model["warnings"]))

    def git_observation_fault(self, repeated=False, head=False):
        self.inject("import subprocess\noriginal = subprocess.run\ncount = 0\n"
                    "def run(args, *a, **kw):\n"
                    "    global count\n"
                    "    result = original(args, *a, **kw)\n"
                    "    if isinstance(args, list) and args and args[0] == 'git' and "
                    + ("'--verify' in args" if head else "'status' in args") + ":\n"
                    "        count += 1\n"
                    "        if " + ("True" if repeated else "count <= 2") + ":\n"
                    "            result.stdout = "
                    + ("((b'a' if count % 2 else b'b') * 40) + b'\\n'" if head
                       else "b'?? ' + (b'first' if count % 2 else b'second') + b'.txt\\0'") + "\n"
                    "    return result\nsubprocess.run = run\n")

    def test_git_retries_changed_head_and_status(self):
        self.init_git()
        for head in (False, True):
            self.git_observation_fault(head=head)
            model = self.success(self.run_ctx("view"))
            self.assertEqual(model["git"]["status"], "available")

    def test_git_repeated_changes_are_unavailable(self):
        self.init_git()
        self.git_observation_fault(repeated=True)
        model = self.success(self.run_ctx("view"))
        self.assertEqual(model["git"]["status"], "unavailable")
        self.assertTrue(any("changed during" in warning["message"] for warning in model["warnings"]))

    def test_commit_batch_failure_preserves_git_snapshot(self):
        head = self.init_git()
        self.write_jsonl("work-log/timeline.jsonl", [self.record(commit=head)])
        self.inject("import subprocess\noriginal = subprocess.run\n"
                    "def run(args, *a, **kw):\n"
                    "    if isinstance(args, list) and args and args[0] == 'git' and 'cat-file' in args:\n"
                    "        return subprocess.CompletedProcess(args, 128, b'', b'injected batch failure')\n"
                    "    return original(args, *a, **kw)\nsubprocess.run = run\n")
        model = self.success(self.run_ctx("view"))
        self.assertEqual(model["git"]["status"], "available")
        self.assertEqual(model["entries"][0]["commitObjectStatus"], "unavailable")
        self.assertTrue(any("batch failure" in warning["message"] for warning in model["warnings"]))
