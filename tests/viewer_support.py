"""Shared fixtures for the standalone local context viewer CLI."""

import json
import os
from html.parser import HTMLParser
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class _ViewDataParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.collecting = False
        self.blocks = []
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag == "script" and dict(attrs).get("id") == "ctx-view-data":
            self.collecting = True
            self.parts = []

    def handle_data(self, data):
        if self.collecting:
            self.parts.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.collecting:
            self.blocks.append("".join(self.parts))
            self.collecting = False


class BaseViewCase(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ctx-kit-view-test-")
        self.addCleanup(temporary.cleanup)
        self.project = Path(temporary.name).resolve()
        self.script = self.project / "ctx.sh"
        shutil.copy2(REPO / "ctx.sh", self.script)
        self.context = self.project / "context"
        self.context.mkdir()
        self.output = self.context / "generated/view.html"
        (self.project / "ctx.config.json").write_text(json.dumps({
            "source": "context/AGENT_RULES.md", "agent_rules": [],
            "git_sync": {"enabled": False},
        }), encoding="utf-8")
        (self.context / "MASTER_PLAN.md").write_text(
            "# Example\n\n## Current State\nReady to resume.\n\n"
            "## Next Actions\n- [ ] Review the next task.\n", encoding="utf-8")
        self.env = dict(
            os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="Viewer Test", GIT_AUTHOR_EMAIL="viewer@example.invalid",
            GIT_COMMITTER_NAME="Viewer Test", GIT_COMMITTER_EMAIL="viewer@example.invalid",
            PYTHONDONTWRITEBYTECODE="1",
        )
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
            self.env.pop(name, None)

    def run_ctx(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.script), *args], cwd=self.project,
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=45,
        )

    def write_jsonl(self, relative_path, entries):
        path = self.context / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(item, ensure_ascii=False) + "\n"
                                for item in entries), encoding="utf-8")
        return path

    def read_view_model(self, output=None):
        parser = _ViewDataParser()
        parser.feed(Path(output or self.output).read_text(encoding="utf-8"))
        self.assertEqual(len(parser.blocks), 1, "Expected one ctx-view-data block")
        return json.loads(parser.blocks[0])

    def source_snapshot(self):
        paths = [self.project / "ctx.config.json"]
        for pattern in ("*.md", "work-log/*.md", "work-log/*.jsonl", "archive/*.md",
                        "archive/timeline-*.jsonl", "work-log/.ctx-archive-transaction.json"):
            paths.extend(self.context.glob(pattern))
        return {str(path.relative_to(self.project)): path.read_bytes()
                for path in paths if path.is_file() and not path.is_symlink()}

    def git(self, *args):
        result = subprocess.run(
            ["git", *args], cwd=self.project, env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()
