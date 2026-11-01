"""CLI errors must fail before rewriting configuration or context files."""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class CliErrorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-cli-errors-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve() / "project's 한글 space"
        self.project.mkdir()
        self.script = self.project / "ctx.sh"
        shutil.copy2(REPO / "ctx.sh", self.script)
        self.config = self.project / "ctx.config.json"
        self.document = {
            "source": "context's 한글 folder/AGENT_RULES.md",
            "agent_rules": [{"name": "Codex", "path": "AGENTS.md", "enabled": True}],
            "git_sync": {"enabled": False, "auto_log": False},
        }
        self.context = self.project / Path(self.document["source"]).parent
        self.context.mkdir()
        (self.context / "AGENT_RULES.md").write_text("# Rules\n", encoding="utf-8")
        (self.context / "MASTER_PLAN.md").write_text(
            "# Plan\n> Last Updated: 2000-01-01\n", encoding="utf-8"
        )
        self.write_config(self.document)

    def write_config(self, document):
        self.config.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
        self.config.chmod(0o640)

    def run_ctx(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.script), *args], cwd=self.project.parent,
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20,
        )

    def snapshot(self):
        entries = {}
        for path in sorted(self.project.rglob("*")):
            info = path.lstat()
            content = os.readlink(path) if path.is_symlink() else (
                path.read_bytes() if path.is_file() else None
            )
            entries[str(path.relative_to(self.project))] = (
                info.st_ino, info.st_mode, content
            )
        return entries

    def assert_rejected_without_changes(self, args, diagnostic=None):
        before = self.snapshot()

        result = self.run_ctx(*args)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(result.stderr.strip(), result.stdout)
        if diagnostic:
            self.assertIn(diagnostic, result.stderr)
        self.assertEqual(self.snapshot(), before)
        for message in ("Sync complete.", "Export complete.", "→ Codex enabled", "→ Codex disabled"):
            self.assertNotIn(message, result.stdout)
        return result

    def test_unknown_command_returns_error_without_configuration(self):
        self.config.unlink()
        self.assert_rejected_without_changes(("sycn",), "sycn")

    def test_unknown_agent_does_not_rewrite_config_or_sync(self):
        for command in ("enable", "disable"):
            with self.subTest(command=command):
                self.assert_rejected_without_changes((command, "Missing agent's 한글"), "not found")

    def test_empty_agent_list_rejects_unknown_agent_without_writing(self):
        self.document["agent_rules"] = []
        self.write_config(self.document)
        for command in ("enable", "disable"):
            with self.subTest(command=command):
                self.assert_rejected_without_changes((command, "Codex"), "not found")

    def test_list_rejects_unreadable_configuration_content(self):
        for content in (b"{ broken JSON", b"\xff\xfe"):
            with self.subTest(content=content):
                self.config.write_bytes(content)
                result = self.assert_rejected_without_changes(("list",))
                self.assertNotIn("Enable:  bash", result.stdout)

    def test_agent_read_errors_propagate_before_partial_display_or_sync(self):
        cases = []
        missing = copy.deepcopy(self.document)
        del missing["agent_rules"]
        cases.append(missing)
        for rows in (None, "invalid rows", [{"name": "Missing fields"}],
                     [{"path": "OTHER.md", "enabled": True}],
                     self.document["agent_rules"] + [{"name": "Broken row"}]):
            document = copy.deepcopy(self.document)
            document["agent_rules"] = rows
            cases.append(document)
        for index, document in enumerate(cases):
            for command in ("list", "status", "sync"):
                with self.subTest(case=index, command=command):
                    self.write_config(document)
                    result = self.assert_rejected_without_changes((command,))
                    self.assertNotIn("●", result.stdout)
                    self.assertNotIn("Codex: AGENTS.md", result.stdout)
                    self.assertNotIn("Enable:  bash", result.stdout)

    def test_unknown_init_options_do_not_create_templates_or_config(self):
        self.config.unlink()
        self.assert_rejected_without_changes(
            ("init", "--no-hook", "--no-backfill", "--bogus"), "--bogus"
        )

    def test_unknown_export_option_is_rejected(self):
        self.assert_rejected_without_changes(("export", "--bogus"), "--bogus")

    def test_unknown_log_option_does_not_record_work(self):
        for command in ("log", "record"):
            with self.subTest(command=command):
                self.assert_rejected_without_changes((command, "--summry", "typo"), "--summry")

    def test_invalid_limits_fail_even_without_logs_or_git_history(self):
        for command in ("timeline", "backfill"):
            for value in ("abc", "-1", "1.5", ""):
                with self.subTest(command=command, value=value):
                    self.assert_rejected_without_changes((command, "--limit", value), "--limit")

    def test_help_defaults_and_version_remain_successful_without_config(self):
        self.config.unlink()
        for args in ((), ("help",), ("--help",), ("-h",), ("version",)):
            with self.subTest(args=args):
                before = self.snapshot()
                result = self.run_ctx(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("ctx", result.stdout)
                self.assertEqual(self.snapshot(), before)

    def test_empty_agent_list_is_valid_for_list_status_and_sync(self):
        self.document["agent_rules"] = []
        self.write_config(self.document)
        for command in ("list", "status", "sync"):
            with self.subTest(command=command):
                result = self.run_ctx(command)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("(disabled)", result.stdout)

    def test_zero_limits_and_export_all_remain_successful(self):
        for args in (("timeline", "--limit", "0"), ("backfill", "--limit", "0"),
                     ("export", "--all")):
            with self.subTest(args=args):
                before = self.snapshot()
                result = self.run_ctx(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_log_accepts_positional_and_explicit_summary_values(self):
        cases = (
            (("log", "user's", "한글", "summary"), "user's 한글 summary"),
            (("record", "--summary", "--literal summary"), "--literal summary"),
        )
        for args, expected in cases:
            with self.subTest(args=args):
                result = self.run_ctx(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                log_file = self.context / "work-log/timeline.jsonl"
                entries = [json.loads(line) for line in log_file.read_text(encoding="utf-8").splitlines()]
                self.assertEqual(entries[-1]["summary"], expected)


if __name__ == "__main__":
    unittest.main()
