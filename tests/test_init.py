"""Standalone initialization and session-closure CLI regression checks."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class InitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-test-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve()

    def install(self, source="sample-context/AGENT_RULES.md", scripts=False):
        self.script = self.project / ("scripts/ctx.sh" if scripts else "ctx.sh")
        self.script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / "ctx.sh", self.script)
        config = json.loads((REPO / "ctx.config.json").read_text(encoding="utf-8"))
        config["source"] = source
        (self.project / "ctx.config.json").write_text(
            json.dumps(config), encoding="utf-8"
        )
        self.context = self.project / Path(source).parent

    def run_ctx(self, *args):
        return subprocess.run(
            ["bash", str(self.script), *args],
            cwd=self.project,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def initialize(self):
        result = self.run_ctx("init", "--no-hook", "--no-backfill")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_standalone_init_matches_documented_rules(self):
        self.install()
        self.initialize()
        self.assertEqual(
            (self.context / "AGENT_RULES.md").read_text(encoding="utf-8"),
            (REPO / "AGENT_RULES.md").read_text(encoding="utf-8"),
        )
        for link in ("AGENTS.md", "CLAUDE.md", ".cursor/rules/context.mdc"):
            self.assertEqual(
                (self.project / link).resolve(), self.context / "AGENT_RULES.md"
            )

    def test_standalone_init_without_config_uses_same_rules(self):
        self.install()
        (self.project / "ctx.config.json").unlink()
        self.initialize()
        self.assertEqual(
            (self.context / "AGENT_RULES.md").read_text(encoding="utf-8"),
            (REPO / "AGENT_RULES.md").read_text(encoding="utf-8"),
        )

    def test_custom_context_renders_document_links(self):
        self.install(source="docs/team context/AGENT_RULES.md")
        self.initialize()
        rules = (self.context / "AGENT_RULES.md").read_text(encoding="utf-8")
        expected = (REPO / "AGENT_RULES.md").read_text(encoding="utf-8").replace(
            "sample-context/", "docs/team context/"
        )
        self.assertEqual(rules, expected)
        plan = (self.context / "MASTER_PLAN.md").read_text(encoding="utf-8")
        for name in ("decisions.md", "backlog.md"):
            self.assertIn(f"docs/team context/{name}", plan)
        self.assertNotIn("sample-context/", plan)

    def test_scripts_install_renders_executable_cli_examples(self):
        self.install(source=".ctx-local/AGENT_RULES.md", scripts=True)
        self.initialize()
        rules = (self.context / "AGENT_RULES.md").read_text(encoding="utf-8")
        expected = (
            (REPO / "AGENT_RULES.md")
            .read_text(encoding="utf-8")
            .replace("sample-context/", ".ctx-local/")
            .replace("bash ctx.sh", "bash scripts/ctx.sh")
        )
        self.assertEqual(rules, expected)
        recorded = self.run_ctx("log", "--summary", "Verified scripts installation")
        self.assertEqual(recorded.returncode, 0, recorded.stderr)
        log_readme = (self.context / "work-log/README.md").read_text(encoding="utf-8")
        self.assertIn("bash scripts/ctx.sh log", log_readme)

    def test_reinitialization_preserves_customized_context(self):
        self.install()
        self.initialize()
        rules = self.context / "AGENT_RULES.md"
        customized = "# Project-specific rules\nKeep existing instructions.\n"
        rules.write_text(customized, encoding="utf-8")
        plan = self.context / "MASTER_PLAN.md"
        with plan.open("a", encoding="utf-8") as stream:
            stream.write("\nProject-specific next action.\n")
        self.initialize()
        self.assertEqual(rules.read_text(encoding="utf-8"), customized)
        self.assertIn("Project-specific next action.", plan.read_text(encoding="utf-8"))
        self.assertFalse((self.context / "work-log/timeline.jsonl").exists())

    def test_closure_log_can_be_verified_through_cli(self):
        self.install(source="docs/context/AGENT_RULES.md")
        self.initialize()
        result = self.run_ctx(
            "log", "--summary", "Updated documentation; validation passed",
            "--files", "README.md", "--type", "docs",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        readback = self.run_ctx("timeline", "--limit", "1", "--json")
        self.assertEqual(readback.returncode, 0, readback.stderr)
        entries = json.loads(readback.stdout)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["summary"], "Updated documentation; validation passed")
        self.assertEqual(entries[0]["files"], ["README.md"])
        self.assertEqual(entries[0]["type"], "docs")

    def test_failed_log_does_not_report_success(self):
        self.install()
        self.initialize()
        # A directory at the log path makes append fail on every supported OS.
        (self.context / "work-log/timeline.jsonl").mkdir(parents=True)
        result = self.run_ctx("log", "--summary", "Cannot persist this work unit")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Recorded work-log entry:", result.stdout)


if __name__ == "__main__":
    unittest.main()
