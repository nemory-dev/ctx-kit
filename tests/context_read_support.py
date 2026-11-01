"""Fixtures for the standalone context search and grounded handoff commands."""

import hashlib
import json
import os
import subprocess
import sys

from viewer_support import BaseViewCase, REPO


class ContextReadCase(BaseViewCase):
    def read_stdout_json(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def search(self, query, *args):
        return self.read_stdout_json(self.run_ctx("search", "--query", query, "--json", *args))

    def handoff(self, *args):
        return self.read_stdout_json(self.run_ctx("handoff", "--json", "--max-chars", "100000", *args))

    def complete_plan(self, extra=""):
        content = ("# Plan\n\n## Constraints\nDo not publish.\n\n"
                   "## Current State\nCache ready.\n\n## Next Actions\nTest timeout.\n\n"
                   "## Verification\nReported unittest pass.\n\n"
                   "## Unverified\nWindows not run.\n" + extra)
        (self.context / "MASTER_PLAN.md").write_text(content, encoding="utf-8")
        return content

    def assert_source(self, source):
        path = (self.context if source["root"] == "context" else self.project) / source["path"]
        data = path.read_bytes()
        self.assertEqual(source["sha256"], hashlib.sha256(data).hexdigest())
        if source["startLine"] is not None:
            self.assertGreaterEqual(source["startLine"], 1)
            self.assertGreaterEqual(source["endLine"], source["startLine"])
            line_count = data.count(b"\n") + int(bool(data) and not data.endswith(b"\n"))
            self.assertLessEqual(source["endLine"], line_count)

    def helpers(self):
        script = (REPO / "ctx.sh").read_text(encoding="utf-8")
        body = script.split("# CTX_VIEW_IMPLEMENTATION_START\n", 1)[1].split("# CTX_VIEW_IMPLEMENTATION_END", 1)[0]
        namespace = dict(os=os, sys=sys, json=json, hashlib=hashlib, subprocess=subprocess)
        exec(compile(body, "<embedded context reader>", "exec"), namespace)
        return namespace

    def helper(self, name):
        namespace = self.helpers()
        self.assertIn(name, namespace, "New context helper has not been implemented")
        return namespace[name]
