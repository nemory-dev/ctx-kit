"""Grounding, strict Markdown boundaries and format-specific output budgets."""

import json

from context_read_support import ContextReadCase


class HandoffTests(ContextReadCase):
    def test_complete_sections_have_exact_sources_and_fixed_order(self):
        self.complete_plan()
        data = self.handoff()
        self.assertEqual(data["status"], "complete")
        self.assertFalse(data["grantsAuthority"])
        self.assertEqual([s["key"] for s in data["mandatory"]],
                         ["constraints", "current_state", "next_actions", "recorded_verification", "recorded_unverified"])
        lines = (self.context / "MASTER_PLAN.md").read_text().splitlines(keepends=True)
        for section in data["mandatory"]:
            self.assertEqual(section["status"], "present")
            for block in section["blocks"]:
                self.assert_source(block["source"])
                source = block["source"]
                self.assertEqual(block["text"], "".join(lines[source["startLine"] - 1:source["endLine"]]))

    def test_missing_verification_is_not_inferred_from_log(self):
        self.write_jsonl("work-log/timeline.jsonl", [{"title": "all tests passed", "summary": "success", "commit": "pending", "dirty": False}])
        data = self.handoff()
        self.assertEqual(data["status"], "incomplete")
        section = next(s for s in data["mandatory"] if s["key"] == "recorded_verification")
        self.assertEqual(section["status"], "missing")
        self.assertEqual(section["blocks"], [])

    def test_fences_comments_and_nested_headings_are_not_promoted(self):
        content = ("# Plan\n## Constraints\nKeep files.\n```text\n## Next Actions\nFake.\n```\n"
                   "<!--\n## Verification\nFake.\n-->\n### Details\nStill constraints.\n"
                   "> ## Unverified\nQuoted.\n    ## Current State\nIndented.\n")
        (self.context / "MASTER_PLAN.md").write_text(content)
        data = self.handoff()
        sections = {s["key"]: s for s in data["mandatory"]}
        self.assertEqual(sections["constraints"]["status"], "present")
        for key in ("next_actions", "recorded_verification", "recorded_unverified", "current_state"):
            self.assertEqual(sections[key]["status"], "missing")

    def test_ambiguous_boundaries_exclude_entire_required_block(self):
        for boundary in (" ## Next Actions\nUnsafe.", "Deployment\n---\nUnsafe.", "<!-- not closed\nUnsafe."):
            with self.subTest(boundary=boundary):
                (self.context / "MASTER_PLAN.md").write_text("## Constraints\nKeep.\n" + boundary)
                section = self.handoff()["mandatory"][0]
                self.assertEqual(section["status"], "ambiguous")
                self.assertEqual(section["blocks"], [])

    def test_duplicate_sections_are_all_preserved_with_warning(self):
        self.complete_plan("\n## Constraints\nSecond constraint.\n")
        data = self.handoff()
        self.assertEqual(len(data["mandatory"][0]["blocks"]), 2)
        self.assertIn("duplicate_heading", [w["code"] for w in data["warnings"]["byCode"]])

    def test_empty_comment_or_subheading_only_is_missing(self):
        for body in (" \t\n", "<!-- ignored -->\n", "### Detail\n"):
            (self.context / "MASTER_PLAN.md").write_text("## Constraints\n" + body)
            self.assertEqual(self.handoff()["mandatory"][0]["status"], "missing")

    def test_korean_closed_headings_bom_and_crlf(self):
        (self.context / "MASTER_PLAN.md").write_bytes(("\ufeff# 계획\r\n## 제약 조건 ##\r\n보존.\r\n"
                "## 현재 상태\r\n구현.\r\n## 다음 행동\r\n검증.\r\n"
                "## 검증\r\n보고.\r\n## 미검증\r\nWindows.\r\n").encode("utf-8"))
        data = self.handoff()
        self.assertEqual(data["status"], "complete")
        self.assertIn("\r", data["mandatory"][0]["blocks"][0]["text"])
        result = self.run_ctx("handoff", "--max-chars", "100000")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(r"\u000d", result.stdout)
        self.assertGreater(data["displayStats"]["crlfPairs"], 0)

    def test_all_record_occurrences_and_raw_large_number_survive(self):
        path = self.write_jsonl("work-log/timeline.jsonl", [])
        line = ' { "title": "same", "number": 9007199254740993 } '
        path.write_text(line + "\n" + line + "\n")
        self.write_jsonl("archive/timeline-old.jsonl", [{"title": "same"}])
        data = self.handoff()
        self.assertEqual(len(data["records"]), 3)
        self.assertEqual(len({r["ref"] for r in data["records"]}), 3)
        self.assertEqual([r["recordText"] for r in data["records"]].count(line), 2)

    def test_query_limit_and_selection_identity(self):
        self.write_jsonl("work-log/timeline.jsonl", [{"title": "match %d" % i} for i in range(8)])
        for limit in ("0", "2", "5"):
            data = self.handoff("--query", "match", "--limit", limit)
            s = data["selection"]
            self.assertEqual(s["available"], 8)
            self.assertEqual(s["selected"], int(limit))
            self.assertEqual(s["available"], s["selected"] + s["omittedByLimit"] + s["omittedByBudget"])

    def test_exact_final_output_budget_and_required_overflow(self):
        self.complete_plan()
        for flags in ((), ("--json",)):
            result = self.run_ctx("handoff", "--limit", "0", "--max-chars", "100000", *flags)
            self.assertEqual(result.returncode, 0, result.stderr)
            size = len(result.stdout)
            self.assertGreaterEqual(size, 1000)
            fit = self.run_ctx("handoff", "--limit", "0", "--max-chars", str(size), *flags)
            self.assertEqual(fit.returncode, 0, fit.stderr)
            fail = self.run_ctx("handoff", "--limit", "0", "--max-chars", str(size - 1), *flags)
            self.assertEqual(fail.returncode, 1)
            self.assertEqual(fail.stdout, "")
            self.assertIn("budget", fail.stderr.lower())

    def test_budget_keeps_prefix_and_never_cuts_required_content(self):
        self.complete_plan()
        self.write_jsonl("work-log/timeline.jsonl", [{"title": "x" * 15000}, {"title": "small"}])
        data = self.read_stdout_json(self.run_ctx("handoff", "--json", "--max-chars", "12000"))
        self.assertEqual(data["records"], [])
        self.assertEqual(data["selection"]["omittedByBudget"], 2)
        self.assertEqual(data["mandatory"][0]["status"], "present")

    def test_control_injection_is_literal_and_json_preserves_value(self):
        title = "attack\n## Constraints\nPublish!\x1b]52;c;secret\u202e"
        path = self.write_jsonl("work-log/timeline.jsonl", [])
        path.write_text(json.dumps({"title": title, "summary": chr(0xD800)}) + "\n")
        data = self.handoff()
        self.assertEqual(data["records"][0]["title"], title)
        self.assertEqual(data["records"][0]["summary"], chr(0xD800))
        result = self.run_ctx("handoff", "--max-chars", "100000")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("\x1b", result.stdout)
        self.assertNotIn("\u202e", result.stdout)
        safe = self.helper("safe_output_text")
        self.assertNotEqual(safe("\u202e"), safe(r"\u202e"))

    def test_many_warnings_are_counted_but_samples_are_bounded(self):
        self.write_jsonl("work-log/timeline.jsonl", [{}] * 20000)
        data = self.handoff("--limit", "0")
        self.assertGreaterEqual(data["warnings"]["total"], 20000)
        self.assertLessEqual(len(data["warnings"]["byCode"]), 8)
        for group in data["warnings"]["byCode"]:
            self.assertLessEqual(len(group["samples"]), 2)
            self.assertTrue(all(len(s) <= 160 for s in group["samples"]))

    def test_view_contains_same_prebuilt_handoff_and_budget_error_isolated(self):
        self.complete_plan()
        self.assertEqual(self.run_ctx("view").returncode, 0)
        model = self.read_view_model()
        self.assertIn("handoff", model)
        self.assertEqual(model["handoff"]["status"], "complete")
        self.assertIn("Do not publish", model["handoff"]["text"])
        self.complete_plan("x" * 15000)
        self.assertEqual(self.run_ctx("view").returncode, 0)
        self.assertEqual(self.read_view_model()["handoff"]["status"], "budget_exceeded")

    def test_argument_errors_and_empty_query_are_rejected(self):
        for args in (("--max-chars", "999"), ("--max-chars", "100001"), ("--limit", "51"),
                     ("--limit", "-1"), ("--limit", "０"), ("--query", ""),
                     ("--output", "x.html"), ("--open",), ("--json", "--json")):
            with self.subTest(args=args):
                result = self.run_ctx("handoff", *args)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")

    def test_default_limit_is_five_and_complete_does_not_grant_authority(self):
        self.complete_plan()
        self.write_jsonl('work-log/timeline.jsonl', [{'title': str(i)} for i in range(7)])
        packet = self.handoff()
        self.assertEqual(packet['selection']['selected'], 5)
        self.assertFalse(packet['grantsAuthority'])
        self.assertIn('승인', packet['notice'])

    def test_unclosed_fence_near_miss_and_nested_section_boundaries(self):
        (self.context / 'MASTER_PLAN.md').write_text('## Constraints\nKeep.\n### Details\nNested.\n'
            '## Current State extra\nNot state.\n## Next Actions\nRun.\n~~~\n## Verification\nFake.')
        data = self.handoff()
        self.assertEqual(data['mandatory'][0]['blocks'][0]['text'], 'Keep.\n### Details\nNested.\n')
        self.assertEqual(data['mandatory'][1]['status'], 'missing')
        self.assertEqual(data['mandatory'][3]['status'], 'missing')
        codes = {w['code'] for w in data['warnings']['byCode']}
        self.assertIn('ambiguous_markdown', codes)

    def test_git_unavailable_is_not_clean_or_test_success(self):
        directory = self.project / 'bin'
        directory.mkdir()
        executable = directory / 'git'
        executable.write_text('#!/bin/sh\nexit 2\n')
        executable.chmod(0o755)
        self.env['PATH'] = str(directory) + ':' + self.env['PATH']
        packet = self.handoff()
        self.assertEqual(packet['git']['status'], 'unavailable')
        self.assertIsNone(packet['git']['changeCount'])
        self.assertIn('git_unavailable', [w['code'] for w in packet['warnings']['byCode']])

    def test_display_stats_distinguish_crlf_backslash_and_actual_controls(self):
        self.write_jsonl('work-log/timeline.jsonl', [{'title': 'a\r\nb\\c\x1b\u202e'}])
        stats = self.handoff()['displayStats']
        self.assertEqual(stats['crlfPairs'], 1)
        # The selected title has ESC+bidi; recordText also contains the literal bidi.
        self.assertEqual(stats['otherControls'], 3)
        self.assertGreater(stats['literalBackslashes'], 0)
        self.assertEqual(self.helper('safe_output_text')('a\r\nb\\c\x1b'), 'a\nb\\\\c\\u001b')

    def test_budget_uses_actual_counts_across_ten_record_boundary(self):
        self.complete_plan()
        self.write_jsonl('work-log/timeline.jsonl', [{'title': 'r%d' % i} for i in range(11)])
        self.assertEqual(self.run_ctx('view').returncode, 0)
        model = self.read_view_model()
        ns = self.helpers()
        snapshot = dict(documents=model['documents'], entries=model['entries'], snapshotId=model['snapshotId'],
                        sourceLookup={r['path']: r for r in model['sourceManifest'] if r['root'] == 'context'}, collectionFinishedAt=model['collectionFinishedAt'])
        packet = ns['build_handoff'](snapshot, model['git'], dict(query=None, limit=11))
        for fmt in ('json', 'markdown'):
            result, output = ns['fit_handoff'](packet, fmt, 100000)
            size = len(output)
            self.assertEqual(result['selection']['selected'], 11)
            reduced, text = ns['fit_handoff'](packet, fmt, size - 1)
            self.assertEqual(reduced['selection']['selected'], 10)
            self.assertEqual(reduced['selection']['omittedByBudget'], 1)
            self.assertLessEqual(len(text), size - 1)
            if fmt == 'json':
                self.assertEqual(json.loads(text)['selection'], reduced['selection'])

    def test_comment_closing_with_indentation_does_not_hide_real_sections(self):
        (self.context / 'MASTER_PLAN.md').write_text('<!-- comment\n    -->\n## Constraints\nKeep.\n')
        section = self.handoff()['mandatory'][0]
        self.assertEqual(section['status'], 'present')
        self.assertEqual(section['blocks'][0]['text'], 'Keep.\n')

    def test_list_fence_cannot_absorb_later_verification(self):
        for closing in ('  ```', '```'):
            with self.subTest(closing=closing):
                (self.context / 'MASTER_PLAN.md').write_text(
                    '## Next Actions\n- ```bash\n  make test\n' + closing + '\n## Verification\nReported pass.\n')
                data = self.handoff()
                sections = {s['key']: s for s in data['mandatory']}
                self.assertTrue(sections['next_actions']['status'] == 'ambiguous'
                                or sections['recorded_verification']['status'] == 'present')
                for block in sections['next_actions']['blocks']:
                    self.assertNotIn('## Verification', block['text'])

    def test_inline_code_comment_markers_do_not_hide_sections(self):
        for constraint in ('Do not add `<!--` markers.', 'Avoid `<!--` here; then `-->`.',
                           'Use `` `<!--` `` literally.', 'Unmatched ` then ``<!--`` is code.'):
            with self.subTest(constraint=constraint):
                content = self.complete_plan().replace('Do not publish.', constraint).replace('Cache ready.', 'Cache ready.\nthen `-->`')
                (self.context / 'MASTER_PLAN.md').write_text(content)
                data = self.handoff()
                self.assertEqual(data['status'], 'complete')
                self.assertNotIn('## Current State', data['mandatory'][0]['blocks'][0]['text'])

    def test_unsupported_scope_options_are_errors(self):
        for args in (('--scope', 'logs'), ('--scope=all',), ('--scope', 'documents')):
            with self.subTest(args=args):
                result = self.run_ctx('handoff', *args)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, '')

    def test_short_setext_and_empty_atx_end_or_exclude_required_block(self):
        for underline in ('-', '--', '=', '==', '  --'):
            with self.subTest(underline=underline):
                (self.context / 'MASTER_PLAN.md').write_text('## Constraints\nKeep.\nNotes\n' + underline + '\nOutside.\n')
                self.assertEqual(self.handoff()['mandatory'][0]['status'], 'ambiguous')
        for heading in ('#', '##', '##  '):
            with self.subTest(heading=heading):
                (self.context / 'MASTER_PLAN.md').write_text('## Constraints\nKeep.\n' + heading + '\nOutside.\n')
                block = self.handoff()['mandatory'][0]['blocks'][0]
                self.assertEqual(block['text'], 'Keep.\n')

    def test_eof_source_range_counts_physical_lf_lines_only(self):
        for suffix in ('', '\n', '\n\n'):
            (self.context / 'MASTER_PLAN.md').write_text('## Constraints\nKeep.' + suffix)
            source = self.handoff()['mandatory'][0]['blocks'][0]['source']
            self.assertEqual(source['endLine'], 2 + (suffix.count('\n') - 1 if suffix else 0))
            self.assert_source(source)

    def test_only_one_leading_bom_is_accepted(self):
        path = self.context / 'MASTER_PLAN.md'
        path.write_text('\ufeff\ufeff## Constraints\nKeep.\n')
        self.assertEqual(self.handoff()['mandatory'][0]['status'], 'missing')
        path.write_text('\ufeff## Constraints\nKeep.\n')
        self.assertEqual(self.handoff()['mandatory'][0]['status'], 'present')

    def test_crlf_markdown_budget_uses_display_length_lower_bound(self):
        content = self.complete_plan().replace('\n', '\r\n') + '\r\n' * 6000
        (self.context / 'MASTER_PLAN.md').write_bytes(content.encode('utf-8'))
        self.assertEqual(self.run_ctx('view').returncode, 0)
        model = self.read_view_model()
        ns = self.helpers()
        snapshot = dict(documents=model['documents'], entries=model['entries'], snapshotId=model['snapshotId'],
                        sourceLookup={r['path']: r for r in model['sourceManifest'] if r['root'] == 'context'}, collectionFinishedAt=model['collectionFinishedAt'])
        packet = ns['build_handoff'](snapshot, model['git'], dict(query=None, limit=0))
        actual_size = len(ns['render_handoff'](packet, 'markdown'))
        self.assertLess(actual_size, sum(len(b['text']) for s in packet['mandatory'] for b in s['blocks']))
        fit = self.run_ctx('handoff', '--limit', '0', '--max-chars', str(actual_size))
        self.assertEqual(fit.returncode, 0, fit.stderr)
        self.assertEqual(len(fit.stdout), actual_size)
        fail = self.run_ctx('handoff', '--limit', '0', '--max-chars', str(actual_size - 1))
        self.assertEqual((fail.returncode, fail.stdout), (1, ''))

    def test_long_heading_whitespace_finishes_within_deadline(self):
        import os
        import signal
        import subprocess
        if os.name == 'nt':
            self.skipTest('POSIX process group timeout harness')
        (self.context / 'MASTER_PLAN.md').write_text('## a' + ' ' * 200000 + 'b\n')
        for command in ('handoff', 'view'):
            with self.subTest(command=command):
                process = subprocess.Popen(['/bin/bash', str(self.script), command], cwd=self.project,
                                           env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           universal_newlines=True, start_new_session=True)
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
                    self.fail('heading whitespace exceeded 5 seconds')
                self.assertEqual(process.returncode, 0, stdout + stderr)

    def test_escaped_opening_tick_does_not_hide_a_real_comment(self):
        cases = [("\\`", "missing"), ("\\``", "present"),
                 ("\\\\`", "present"), ("\\\\``", "missing")]
        for opening, expected in cases:
            with self.subTest(opening=opening):
                (self.context / 'MASTER_PLAN.md').write_text(
                    '## Constraints\n' + opening + '<!-- real ` comment\n'
                    '## Verification\nFake report.\n-->\n')
                self.assertEqual(self.handoff()['mandatory'][3]['status'], expected)

    def test_list_fence_reclosed_later_does_not_absorb_verification(self):
        (self.context / 'MASTER_PLAN.md').write_text(
            '## Next Actions\n- ```bash\n  make test\n  ```\n'
            '## Verification\nReported pass.\n```sh\necho hi\n```\n')
        data = self.handoff()
        actions = data['mandatory'][2]
        self.assertTrue(actions['status'] == 'ambiguous' or data['mandatory'][3]['status'] == 'present')
        for block in actions['blocks']:
            self.assertNotIn('## Verification', block['text'])

    def test_multiline_inline_code_comment_is_not_silently_absorbed(self):
        (self.context / 'MASTER_PLAN.md').write_text(
            '## Constraints\nUse `x\n<!--` literally.\n## Current State\nS.\nSee `-->`.\n')
        data = self.handoff()
        self.assertTrue(data['mandatory'][0]['status'] == 'ambiguous'
                        or data['mandatory'][1]['status'] == 'present')
        for block in data['mandatory'][0]['blocks']:
            self.assertNotIn('## Current State', block['text'])

    def test_empty_subheading_alone_is_not_a_section_body(self):
        for heading in ('###', '###   ', '### ###'):
            (self.context / 'MASTER_PLAN.md').write_text('## Constraints\n' + heading + '\n')
            self.assertEqual(self.handoff()['mandatory'][0]['status'], 'missing')

    def test_multiline_inline_html_comment_excludes_the_affected_block(self):
        for opener in ('Note <!-- todo', '\\<!-- todo', 'Note <!--` todo'):
            with self.subTest(opener=opener):
                (self.context / 'MASTER_PLAN.md').write_text(
                    '## Constraints\n' + opener + '\n## Verification\nReported pass.\n-->\n')
                section = self.handoff()['mandatory'][0]
                self.assertEqual(section['status'], 'ambiguous')
                self.assertEqual(section['blocks'], [])

    def test_invalid_backtick_fence_info_does_not_absorb_a_section(self):
        for opening in ('```a`b', '```<!-- ` -->'):
            with self.subTest(opening=opening):
                (self.context / 'MASTER_PLAN.md').write_text(
                    '## Constraints\n' + opening + '\n## Verification\nReported pass.\n```\n')
                section = self.handoff()['mandatory'][0]
                self.assertEqual(section['status'], 'ambiguous')
                self.assertEqual(section['blocks'], [])

    def test_abrupt_comment_closes_on_its_opening_line(self):
        for marker in ('<!-->', '<!--->'):
            with self.subTest(marker=marker):
                (self.context / 'MASTER_PLAN.md').write_text(
                    '## Constraints\nKeep X.\n' + marker + '\n'
                    '## Verification\nReported pass.\n-->\n')
                data = self.handoff()
                self.assertEqual(data['mandatory'][3]['status'], 'present')
                self.assertNotIn('## Verification', data['mandatory'][0]['blocks'][0]['text'])
                (self.context / 'MASTER_PLAN.md').write_text('## Constraints\n' + marker + '\nUseful body.\n')
                self.assertEqual(self.handoff()['mandatory'][0]['status'], 'present')
