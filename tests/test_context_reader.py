"""Shared snapshot identity and read-only CLI boundaries."""

import hashlib
import shutil

from context_read_support import ContextReadCase


class ContextReaderTests(ContextReadCase):
    def test_search_copy_preserves_sources_and_does_not_generate(self):
        before = self.source_snapshot()
        result = self.search("Ready")
        self.assertEqual(result["total"], 1)
        self.assertEqual(self.source_snapshot(), before)
        self.assertFalse(self.output.exists())
        self.assert_source(result["results"][0]["source"])

    def test_manifest_matches_collected_bytes_missing_and_empty(self):
        (self.context / "decisions.md").write_bytes(b"")
        self.assertEqual(self.run_ctx("view").returncode, 0)
        model = self.read_view_model()
        self.assertIn("sourceManifest", model)
        rows = {r["path"]: r for r in model["sourceManifest"]}
        self.assertEqual(rows["decisions.md"]["status"], "present")
        self.assertEqual(rows["decisions.md"]["sizeBytes"], 0)
        self.assertEqual(rows["backlog.md"]["status"], "missing")
        self.assertIsNone(rows["backlog.md"]["sha256"])
        self.assertEqual(rows["ctx.config.json"]["root"], "project")

    def test_snapshot_identity_ignores_time_query_and_output(self):
        first = self.search("Ready")
        second = self.search("task")
        self.assertEqual(first["snapshotId"], second["snapshotId"])
        self.assertEqual(self.run_ctx("view", "--output", "reports/test.html").returncode, 0)
        self.assertEqual(first["snapshotId"], self.read_view_model(self.project / "reports/test.html")["snapshotId"])
        with (self.context / "MASTER_PLAN.md").open("a", encoding="utf-8") as stream:
            stream.write("changed\n")
        self.assertNotEqual(first["snapshotId"], self.search("changed")["snapshotId"])

    def test_inherited_action_and_output_cannot_trigger_writes(self):
        self.env.update(CTX_READER_ACTION="view", CTX_VIEW_OUTPUT="rogue.html", CTX_VIEW_OPEN="1")
        self.search("Ready")
        self.assertFalse((self.project / "rogue.html").exists())
        self.assertFalse(self.output.exists())

    def test_both_commands_fail_on_corruption_without_partial_output(self):
        self.write_jsonl("work-log/timeline.jsonl", [])
        path = self.context / "work-log/timeline.jsonl"
        for content in (b'{"bad":', b'[]\n', b'\xff\n'):
            path.write_bytes(content)
            before = self.source_snapshot()
            for args in (("search", "--query", "x"), ("handoff",)):
                result = self.run_ctx(*args)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("timeline.jsonl", result.stderr)
            self.assertEqual(self.source_snapshot(), before)

    def test_pending_archive_is_not_recovered(self):
        directory = self.context / "work-log"
        directory.mkdir()
        journal = directory / ".ctx-archive-transaction.json"
        journal.write_text('{"unfinished":true}', encoding="utf-8")
        for args in (("search", "--query", "x"), ("handoff",)):
            result = self.run_ctx(*args)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertIn("archive", result.stderr.lower())
        self.assertEqual(journal.read_text(), '{"unfinished":true}')

    def test_help_without_config_or_python(self):
        (self.project / "ctx.config.json").unlink()
        binary_dir = self.project / "help-bin"
        binary_dir.mkdir()
        for name in ("dirname", "basename"):
            (binary_dir / name).symlink_to(shutil.which(name))
        self.env["PATH"] = str(binary_dir)
        for command in ("search", "handoff"):
            result = self.run_ctx(command, "--help")
            self.assertEqual(result.returncode, 0)
            self.assertIn(command, result.stdout)

    def test_git_fsmonitor_is_not_executed(self):
        self.git("init", "--quiet")
        marker = self.project / "fsmonitor-ran"
        hook = self.project / "monitor.sh"
        hook.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n', encoding="utf-8")
        hook.chmod(0o755)
        (self.project / "probe.txt").write_text("probe")
        self.git("add", "probe.txt")
        self.git("commit", "-qm", "test fixture")
        self.git("config", "core.fsmonitor", str(hook))
        self.git("status", "--porcelain")
        self.assertTrue(marker.exists(), "positive control must execute fsmonitor")
        marker.unlink()
        index = self.project / ".git/index"
        before = (index.read_bytes(), index.stat().st_mtime_ns)
        self.handoff()
        self.assertEqual((index.read_bytes(), index.stat().st_mtime_ns), before)
        self.assertFalse(marker.exists())

    def test_two_file_scripts_install_and_new_help_entries(self):
        directory = self.project / 'scripts'
        directory.mkdir()
        self.script = self.script.rename(directory / 'ctx.sh')
        self.assertEqual(self.search('Ready')['total'], 1)
        self.assertEqual(self.handoff()['status'], 'incomplete')
        self.assertFalse(self.output.exists())
        help_text = self.run_ctx('--help').stdout
        self.assertIn('search', help_text)
        self.assertIn('handoff', help_text)

    def test_read_commands_enforce_shared_limits_and_unsafe_paths(self):
        path = self.write_jsonl('work-log/timeline.jsonl', [{}] * 20001)
        for args in (('search', '--query', 'x'), ('handoff',)):
            result = self.run_ctx(*args)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
            self.assertIn('20000', result.stderr)
        path.unlink()
        target = self.project / 'outside.md'
        target.write_text('private')
        (self.context / 'decisions.md').symlink_to(target)
        self.assertEqual(self.run_ctx('search', '--query', 'private').stdout, '')
        self.assertEqual(self.run_ctx('handoff').returncode, 1)

    def test_manifest_and_refs_do_not_reread_changed_sources(self):
        self.assertEqual(self.run_ctx('view').returncode, 0)
        model = self.read_view_model()
        source = next(row for row in model['sourceManifest'] if row['path'] == 'MASTER_PLAN.md')
        (self.context / 'MASTER_PLAN.md').write_text('changed')
        ref = self.helper('source_ref')({'sourceLookup': {'MASTER_PLAN.md': source}}, 'MASTER_PLAN.md', 1, 1)
        self.assertEqual(ref['sha256'], source['sha256'])
        self.assertNotEqual(ref['sha256'], hashlib.sha256(b'changed').hexdigest())

    def test_emitter_handles_short_writes_and_propagates_broken_pipe(self):
        from unittest.mock import patch
        emitter = self.helper('emit_stdout')
        fragments = []
        def short_write(fd, data):
            count = min(2, len(data))
            fragments.append(bytes(data[:count]))
            return count
        with patch.object(emitter.__globals__['os'], 'write', short_write):
            emitter('한글\n')
        self.assertEqual(b''.join(fragments), '한글\n'.encode('utf-8'))
        with patch.object(emitter.__globals__['os'], 'write', side_effect=BrokenPipeError('closed')):
            with self.assertRaises(BrokenPipeError):
                emitter('x')

    def test_invalid_config_stops_before_creating_any_context_lock(self):
        for content in ('[]', '{"source":42}', '{bad'):
            (self.project / 'ctx.config.json').write_text(content)
            for command in ('search', 'handoff', 'view'):
                args = ('--query', 'x') if command == 'search' else ()
                result = self.run_ctx(command, *args)
                self.assertEqual((result.returncode, result.stdout), (1, ''))
                self.assertFalse((self.project / 'work-log').exists())
                self.assertFalse((self.context / 'work-log').exists())

    def test_git_observation_preserves_ownership_check(self):
        from unittest.mock import patch
        import subprocess
        collector = self.helper('collect_git_snapshot')
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 128, b'', b'fatal: not a git repository')
        with patch.object(collector.__globals__['subprocess'], 'run', run):
            collector(str(self.project), [], [])
        self.assertTrue(calls)
        self.assertFalse(any('safe.directory=*' in args for args in calls))

    def test_git_clean_filter_side_effect_is_an_explicit_trust_boundary(self):
        import os
        import shlex
        self.git('init', '--quiet')
        marker = self.project / 'clean-filter-ran'
        script = self.project / 'clean-filter.sh'
        script.write_text('#!/bin/sh\ntouch ' + shlex.quote(str(marker)) + '\ncat\n')
        script.chmod(0o755)
        self.git('config', 'filter.probe.clean', shlex.quote(str(script)))
        (self.project / '.gitattributes').write_text('tracked.txt filter=probe\n')
        tracked = self.project / 'tracked.txt'
        tracked.write_text('base\n')
        self.git('add', '.gitattributes', 'tracked.txt')
        self.git('commit', '-qm', 'test fixture')
        self.assertTrue(marker.exists())
        marker.unlink()
        previous_time = tracked.stat().st_mtime_ns
        tracked.write_text('edit\n')
        os.utime(tracked, ns=(previous_time + 2000000000, previous_time + 2000000000))
        before = self.source_snapshot()
        self.handoff()
        # A future Git/runtime may avoid the filter. Source immutability must
        # hold either way; execution was separately reproduced in this review.
        self.assertEqual(self.source_snapshot(), before)
