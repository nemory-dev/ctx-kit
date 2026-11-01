"""Offline HTML, inert input and browser-side viewer behavior regressions."""

import base64
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import shutil
import subprocess

from viewer_support import BaseViewCase


FIXTURES = Path(__file__).parent / "fixtures/viewer/html"


class ViewerHTMLParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.tags = []
        self.scripts = []
        self.styles = []
        self.csp = None
        self.current = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if tag == "meta" and attrs.get("http-equiv") == "Content-Security-Policy":
            self.csp = attrs["content"]
        if tag in ("script", "style"):
            self.current = (tag, attrs, [])

    def handle_data(self, data):
        if self.current:
            self.current[2].append(data)

    def handle_endtag(self, tag):
        if self.current and self.current[0] == tag:
            _, attrs, parts = self.current
            (self.scripts if tag == "script" else self.styles).append((attrs, "".join(parts)))
            self.current = None


class ViewHTMLTests(BaseViewCase):
    def generate(self):
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        html = self.output.read_text(encoding="utf-8")
        parser = ViewerHTMLParser()
        parser.feed(html)
        return html, parser

    def test_inert_attack_data_roundtrips_without_new_elements(self):
        attack = json.loads((FIXTURES / "attacks.json").read_text(encoding="utf-8"))
        (self.context / "MASTER_PLAN.md").write_text(attack["markdown"], encoding="utf-8")
        record = dict(attack, createdAt="2026-10-30T12:00:00+09:00", files=[attack["title"]])
        self.write_jsonl("work-log/timeline.jsonl", [record])
        _, parsed = self.generate()
        self.assertEqual(len(parsed.scripts), 2)
        self.assertEqual(len(parsed.styles), 1)
        self.assertFalse(any(tag in ("img", "iframe", "object", "base") for tag, _ in parsed.tags))
        self.assertEqual(self.read_view_model()["entries"][0]["record"], record)
        data = next(text for attrs, text in parsed.scripts if attrs.get("id") == "ctx-view-data")
        for char in ("<", ">", "&", "\u2028", "\u2029"):
            self.assertNotIn(char, data)

    def test_escaped_lone_surrogate_remains_inert_and_roundtrips(self):
        record = {"title": "bad-" + chr(0xD800), "summary": chr(0xDFFF),
                  "files": ["path-" + chr(0xD800)], "createdAt": "2026-10-30T12:00:00Z"}
        path = self.context / "work-log/timeline.jsonl"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(record, ensure_ascii=True) + "\n", encoding="utf-8")
        self.generate()
        self.assertEqual(self.read_view_model()["entries"][0]["record"], record)

    def test_csp_hashes_match_exact_script_and_style_bytes(self):
        html, parsed = self.generate()
        self.assertEqual(html.splitlines()[0], "<!-- ctx-kit-viewer:1 -->")
        for directive in ("default-src 'none'", "connect-src 'none'", "img-src 'none'",
                          "object-src 'none'", "base-uri 'none'", "form-action 'none'"):
            self.assertIn(directive, parsed.csp)
        for attrs, content in parsed.scripts + parsed.styles:
            if attrs.get("id") == "ctx-view-data":
                continue
            digest = base64.b64encode(hashlib.sha256(content.encode("utf-8")).digest()).decode("ascii")
            self.assertIn("'sha256-" + digest + "'", parsed.csp)
        self.assertNotIn("'unsafe-inline'", parsed.csp)
        self.assertFalse(any("src" in attrs or tag == "link" for tag, attrs in parsed.tags))

    def test_offline_shell_has_accessible_controls_and_no_dynamic_code(self):
        _, parsed = self.generate()
        ids = {attrs.get("id") for _, attrs in parsed.tags}
        self.assertTrue({"view-overview", "view-timeline", "view-documents", "search",
                         "entry-list", "entry-detail", "document-content"}.issubset(ids))
        javascript = next(text for attrs, text in parsed.scripts if attrs.get("id") != "ctx-view-data")
        for forbidden in ("innerHTML", "outerHTML", "eval(", "new Function", "fetch(",
                          "localStorage", "XMLHttpRequest", "import("):
            self.assertNotIn(forbidden, javascript)
        self.assertIn("compositionstart", javascript)
        self.assertIn("compositionend", javascript)

    def test_browser_logic_search_filters_pages_and_hash(self):
        if not shutil.which("node"):
            self.skipTest("Node unavailable; browser behavior is checked separately")
        nfc, nfd = "한글.kt", "한글.kt"
        entries = [{"id": "same", "title": "Task %03d" % i, "type": "work",
                    "summary": "요약", "createdAt": "2026-10-30T12:00:00+09:00",
                    "files": [nfc if i % 2 else nfd]} for i in range(55)]
        entries[0]["rawNumeric"] = 9007199254740993
        entries[0]["fullCommit"] = "a" * 40
        entries.append({"title": "Legacy", "type": "custom", "createdAt": "2026-10-30", "files": []})
        plan = self.context / "MASTER_PLAN.md"
        plan.write_text("# Example\n\n## Current State\nReady to resume.\n\n"
                        "```text\n## Next Actions\ncode\n```not-closing\n"
                        "## Next Actions\nstill code\n```\n\n"
                        "## Next Actions\n- [ ] Review the next task.\n" +
                        "\n## C#\nLanguage heading\n\n## Title ###\nClosing heading\n"
                        "\nMARKDOWN_TEST\n\n1. ordered\n2. second\n\n> quote\n\n"
                        "`inline`\n\n```text\n<script>inert</script>\n```\n\n"
                        "[safe](https://example.invalid/docs)\n[bad](javascript:alert(1))\n"
                        "[internal](#current-state)\n[decisions](decisions.md#decision)\n"
                        "[outside](../MASTER_PLAN.md)\n[missing](outside.md)\n"
                        "![image](https://example.invalid/tracker)\n<img src=raw>\n\n"
                        "| column | value |\n| --- | --- |\n| raw | text |\n", encoding="utf-8")
        (self.context / "decisions.md").write_text("# Decision\nExplicit decision text.\n", encoding="utf-8")
        self.write_jsonl("work-log/timeline.jsonl", entries)
        _, parsed = self.generate()
        js = next(text for attrs, text in parsed.scripts if attrs.get("id") != "ctx-view-data")
        result = subprocess.run(["node", str(FIXTURES / "browser-harness.js")],
                                input=json.dumps({"model": self.read_view_model(), "script": js}),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                universal_newlines=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("viewer behavior passed", result.stdout)
