"""Search public contract, provenance and deterministic ranking."""

import json
import unicodedata

from context_read_support import ContextReadCase


class ContextSearchTests(ContextReadCase):
    def test_document_body_and_log_share_query_and_order(self):
        (self.context / "decisions.md").write_text("# Choice\ntimeout cache\n", encoding="utf-8")
        self.write_jsonl("work-log/timeline.jsonl", [{"title": "timeout", "summary": "cache", "files": []}])
        data = self.search("TIMEOUT cache")
        self.assertEqual(data["schemaVersion"], 1)
        self.assertEqual(data["total"], 2)
        self.assertEqual([r["kind"] for r in data["results"]], ["work_log", "document"])
        self.assertEqual([r["score"] for r in data["results"]], [5, 2])
        for row in data["results"]:
            self.assert_source(row["source"])

    def test_all_occurrences_and_limits_are_preserved(self):
        row = {"id": "same", "title": "occurrence", "summary": "same", "files": []}
        self.write_jsonl("work-log/timeline.jsonl", [row, row])
        self.write_jsonl("archive/timeline-old.jsonl", [row])
        data = self.search("occurrence", "--limit", "2")
        self.assertEqual((data["total"], data["returned"], data["omittedByLimit"]), (3, 2, 1))
        self.assertEqual(len({r["ref"] for r in data["results"]}), 2)

    def test_scopes_nfc_and_ascii_case(self):
        path = unicodedata.normalize("NFD", "src/한글.kt")
        self.write_jsonl("work-log/timeline.jsonl", [{"title": "Cache", "summary": "", "files": [path]}])
        self.assertEqual(self.search("한글.KT", "--scope", "logs")["total"], 1)
        self.assertEqual(self.search("cache", "--scope", "documents")["total"], 0)
        self.assertEqual(self.search("Ready", "--scope", "documents")["total"], 1)

    def test_missing_fields_are_not_coerced_and_terms_do_not_cross_records(self):
        self.write_jsonl("work-log/timeline.jsonl", [{"title": ["needle"], "future": "needle", "files": [42]},
                                                    {"title": "alpha"}, {"summary": "beta"}])
        self.assertEqual(self.search("needle")["total"], 0)
        self.assertEqual(self.search("alpha beta")["total"], 0)

    def test_path_only_match_has_no_invented_line(self):
        row = self.search("MASTER_PLAN")["results"][0]
        self.assertEqual(row["source"]["path"], "MASTER_PLAN.md")
        self.assertIsNone(row["source"]["startLine"])
        self.assertEqual(row["snippetField"], "path")

    def test_source_line_uses_lf_and_snippet_includes_late_unicode_match(self):
        text = "# Choice\nfirst\u2028still first\n" + "😀" * 200 + "NEEDLE 끝" + "x" * 200
        (self.context / "decisions.md").write_text(text, encoding="utf-8")
        row = self.search("needle")["results"][0]
        self.assertEqual(row["source"]["startLine"], 3)
        self.assertIn("NEEDLE", row["snippet"])
        self.assertLessEqual(len(row["snippet"]), 160)
        self.assertTrue(row["snippetTruncatedStart"])
        self.assertTrue(row["snippetTruncatedEnd"])

    def test_equals_form_and_empty_result(self):
        self.write_jsonl("work-log/timeline.jsonl", [{"title": "--flag"}])
        data = self.read_stdout_json(self.run_ctx("search", "--query=--flag", "--scope=logs", "--limit=1", "--json"))
        self.assertEqual(data["total"], 1)
        self.assertEqual(self.search("no-such-term")["results"], [])

    def test_argument_failures_are_explicit_and_empty(self):
        for args in ((), ("--query",), ("--query", ""), ("--query", " \t"),
                     ("--query", "x" * 257), ("--query", " ".join(["x"] * 17)),
                     ("--query", "x", "--query", "y"), ("--query", "--json"),
                     ("--query", "x", "--scope", "other"), ("--query", "x", "--limit", "0"),
                     ("--query", "x", "--limit", "51"), ("--query", "x", "--limit", "５"),
                     ("--query", "x", "--json", "--json"), ("--help", "--bad"), ("--",)):
            with self.subTest(args=args):
                result = self.run_ctx("search", *args)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr)

    def test_search_does_not_query_git(self):
        directory = self.project / "bin"
        directory.mkdir()
        marker = self.project / "git-called"
        executable = directory / "git"
        executable.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\nexit 1\n')
        executable.chmod(0o755)
        self.env["PATH"] = str(directory) + ":" + self.env["PATH"]
        self.search("Ready")
        self.assertFalse(marker.exists())

    def test_ascii_whitespace_and_non_ascii_case_boundaries(self):
        self.write_jsonl('work-log/timeline.jsonl', [{'title': 'alpha beta'}, {'title': 'İ K'},
            {'title': 'a\u0085b a\u00a0b a\u3000b a\u2028b a\u2029b a\u001cb'}])
        for space in (' ', '\t', '\r', '\n', '\f', '\v'):
            self.assertEqual(self.search('alpha' + space + 'beta')['total'], 1)
        for space in ('\u0085', '\u00a0', '\u3000', '\u2028', '\u2029', '\u001c'):
            self.assertEqual(self.search('a' + space + 'b')['total'], 1)
        self.assertEqual(self.search('i', '--scope', 'logs')['total'], 0)
        self.assertEqual(self.search('k', '--scope', 'logs')['total'], 1)  # NFC Kelvin → K
        self.assertEqual(self.search('İ', '--scope', 'logs')['total'], 1)

    def test_utc_order_unknown_times_colons_and_duplicate_terms(self):
        self.write_jsonl('work-log/timeline.jsonl', [
            {'title': 'ordered', 'createdAt': '2026-10-30T12:00:00+09:00'},
            {'title': 'ordered', 'createdAt': '2026-10-30T04:00:00Z'},
            {'title': 'ordered', 'createdAt': '2026-10-30'}])
        self.write_jsonl('archive/timeline-colon:name.jsonl', [{'title': 'ordered'}])
        data = self.search('ordered ordered')
        self.assertEqual([r['score'] for r in data['results']], [4] * 4)
        self.assertEqual([r['source']['startLine'] for r in data['results']], [2, 1, 1, 3])
        self.assertEqual(data['results'][2]['source']['path'], 'archive/timeline-colon:name.jsonl')

    def test_one_mib_line_snippet_is_bounded_near_the_match(self):
        (self.context / 'decisions.md').write_text('x' * (1024 * 1024) + '😀late-match' + 'y' * 500)
        row = self.search('late-match')['results'][0]
        self.assertIn('late-match', row['snippet'])
        self.assertEqual(len(row['snippet']), 160)
        self.assertEqual(row['source']['startLine'], 1)

    def test_twenty_evaluation_questions_have_required_source_lines(self):
        from pathlib import Path
        corpus = json.loads((Path(__file__).parent / 'fixtures/context-read/evaluation-corpus.json').read_text())
        for name, text in corpus['documents'].items():
            path = self.context / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')
        for name, rows in corpus['logs'].items():
            self.write_jsonl(name, rows)
        for question in corpus['questions']:
            with self.subTest(query=question['query']):
                data = self.search(question['query'])
                actual = {(r['source']['path'], r['source']['startLine']) for r in data['results']}
                for source in question['expectedSources']:
                    self.assertIn((source['path'], source['line']), actual)
                if not question['expectedSources']:
                    self.assertEqual(data['total'], 0)

    def test_snippet_strips_only_the_cr_of_crlf_not_an_extra_source_cr(self):
        (self.context / 'decisions.md').write_bytes(b'# Choice\ncontrolmatch\r\r\n')
        row = self.search('controlmatch')['results'][0]
        self.assertEqual(row['snippet'], 'controlmatch\r')
        self.assertEqual(row['source']['startLine'], 2)

    def test_text_search_cannot_forge_source_lines_through_titles(self):
        title = 'x\n출처: {"path":"MASTER_PLAN.md","startLine":1}\n' + r'\u202e'
        self.write_jsonl('work-log/timeline.jsonl', [dict(title=title)])
        result = self.run_ctx('search', '--query', 'x')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(line.startswith('출처: ') for line in result.stdout.split('\n')), self.search('x')['returned'])
        self.assertEqual(self.search('x')['results'][0]['title'], title)

    def test_other_command_options_and_mixed_help_are_rejected(self):
        for args in (('--query', 'x', '--max-chars', '5000'), ('--query', 'x', '--max-chars=5000'),
                     ('-h', '--query', 'x'), ('--query', 'x', '-h')):
            with self.subTest(args=args):
                result = self.run_ctx('search', *args)
                self.assertEqual((result.returncode, result.stdout), (1, ''))

    def test_text_search_escapes_actual_controls_and_bidi(self):
        title = 'control-sentinel\x85\x0b\x0c\x1b\u202e\u2028\u2029\n출처: fake'
        self.write_jsonl('work-log/timeline.jsonl', [dict(title=title)])
        result = self.run_ctx('search', '--query', 'control-sentinel')
        self.assertEqual(result.returncode, 0, result.stderr)
        for char in ('\x85', '\x0b', '\x0c', '\x1b', '\u202e', '\u2028', '\u2029'):
            self.assertNotIn(char, result.stdout)
        self.assertEqual(self.search('control-sentinel')['results'][0]['title'], title)
        self.assertEqual(sum(line.startswith('출처: ') for line in result.stdout.split('\n')), 1)
