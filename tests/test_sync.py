"""CLI regression checks for preserving existing agent rule files."""

import json
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-sync-test-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve()
        self.script = self.project / "ctx.sh"
        shutil.copy2(REPO / "ctx.sh", self.script)
        self.source = self.project / "sample-context/AGENT_RULES.md"
        self.config = json.loads((REPO / "ctx.config.json").read_text(encoding="utf-8"))
        self.write_config()

    def write_config(self):
        (self.project / "ctx.config.json").write_text(
            json.dumps(self.config), encoding="utf-8"
        )

    def run_ctx(self, *args):
        return subprocess.run(
            ["bash", str(self.script), *args],
            cwd=self.project,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def prepare_source(self):
        self.source.parent.mkdir(parents=True, exist_ok=True)
        self.source.write_text("# Shared project rules\n", encoding="utf-8")

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_first_init_preserves_existing_agent_files(self):
        originals = {
            "CLAUDE.md": "# Existing Claude instructions\n",
            "AGENTS.md": "# Existing Codex instructions\n",
        }
        for name, content in originals.items():
            (self.project / name).write_text(content, encoding="utf-8")

        result = self.run_ctx("init", "--no-hook", "--no-backfill")

        for name, content in originals.items():
            path = self.project / name
            self.assertFalse(path.is_symlink(), name)
            self.assertEqual(path.read_text(encoding="utf-8"), content)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CLAUDE.md", result.stdout + result.stderr)
        self.assertIn("AGENTS.md", result.stdout + result.stderr)

    def test_sync_conflict_leaves_all_outputs_unchanged(self):
        self.prepare_source()
        master_plan = self.source.parent / "MASTER_PLAN.md"
        master_plan.write_text(
            "# Master Plan\n> Last Updated: 2000-01-01\n", encoding="utf-8"
        )
        existing = self.project / "AGENTS.md"
        existing.write_text("# Keep local rules\n", encoding="utf-8")
        old_link = self.project / "OLD.md"
        old_link.symlink_to("sample-context/AGENT_RULES.md")
        self.config["agent_rules"].append(
            {"name": "Old agent", "path": "OLD.md", "enabled": False}
        )
        self.write_config()
        before_plan = master_plan.read_bytes()

        result = self.run_ctx("sync")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.project / "CLAUDE.md").exists())
        self.assertFalse((self.project / ".cursor").exists())
        self.assertFalse(existing.is_symlink())
        self.assertEqual(existing.read_text(encoding="utf-8"), "# Keep local rules\n")
        self.assertEqual(master_plan.read_bytes(), before_plan)
        self.assertEqual(os.readlink(old_link), "sample-context/AGENT_RULES.md")
        self.assertIn("AGENTS.md", result.stdout + result.stderr)
        self.assertIn("Move or rename", result.stdout + result.stderr)

    def test_sync_preserves_unmanaged_symlink(self):
        self.prepare_source()
        unrelated = self.project / "unrelated.md"
        unrelated.write_text("# Other instructions\n", encoding="utf-8")
        link = self.project / "CLAUDE.md"
        link.symlink_to("unrelated.md")

        result = self.run_ctx("sync")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(os.readlink(link), "unrelated.md")
        self.assertEqual(unrelated.read_text(encoding="utf-8"), "# Other instructions\n")
        self.assertFalse((self.project / "AGENTS.md").exists())

    def test_sync_preserves_broken_unmanaged_symlink(self):
        self.prepare_source()
        link = self.project / "CLAUDE.md"
        link.symlink_to("missing-rules.md")

        result = self.run_ctx("sync")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(os.readlink(link), "missing-rules.md")

    def test_disable_preserves_unmanaged_symlink(self):
        self.prepare_source()
        unrelated = self.project / "unrelated.md"
        unrelated.write_text("# Other instructions\n", encoding="utf-8")
        link = self.project / "CLAUDE.md"
        link.symlink_to("unrelated.md")

        result = self.run_ctx("disable", "Claude")

        self.assert_success(result)
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "unrelated.md")
        self.assertEqual(unrelated.read_text(encoding="utf-8"), "# Other instructions\n")

    def test_disabled_regular_file_is_preserved(self):
        self.prepare_source()
        existing = self.project / "CLAUDE.md"
        existing.write_text("# Existing local rules\n", encoding="utf-8")

        result = self.run_ctx("disable", "Claude")

        self.assert_success(result)
        self.assertFalse(existing.is_symlink())
        self.assertEqual(existing.read_text(encoding="utf-8"), "# Existing local rules\n")

    def test_sync_accepts_existing_links_resolving_to_source(self):
        self.prepare_source()
        alias = self.project / "rules-alias.md"
        alias.symlink_to("sample-context/AGENT_RULES.md")
        link = self.project / "CLAUDE.md"
        link.symlink_to(alias)

        for _ in range(2):
            result = self.run_ctx("sync")
            self.assert_success(result)
            self.assertEqual(link.resolve(), self.source)
            self.assertEqual((self.project / "AGENTS.md").resolve(), self.source)
            self.assertEqual(
                (self.project / ".cursor/rules/context.mdc").resolve(), self.source
            )

    def test_sync_preserves_disabled_link_in_enabled_resolution_chain(self):
        self.prepare_source()
        for disabled_first in (False, True):
            with self.subTest(disabled_first=disabled_first):
                intermediate = self.project / f"OLD-{disabled_first}.md"
                intermediate.symlink_to("sample-context/AGENT_RULES.md")
                active = self.project / f"CLAUDE-{disabled_first}.md"
                active.symlink_to(intermediate.name)
                enabled = {"name": "Claude", "path": active.name, "enabled": True}
                disabled = {"name": "Old agent", "path": intermediate.name, "enabled": False}
                self.config["agent_rules"] = (
                    [disabled, enabled] if disabled_first else [enabled, disabled]
                )
                self.write_config()
                for _ in range(2):
                    self.assert_success(self.run_ctx("sync"))
                    self.assertTrue(intermediate.is_symlink())
                    self.assertEqual(os.readlink(active), intermediate.name)
                    self.assertEqual(active.read_text(), "# Shared project rules\n")

    def test_disabling_shared_path_keeps_link_until_all_agents_disabled(self):
        self.prepare_source()
        self.assert_success(self.run_ctx("sync"))

        self.assert_success(self.run_ctx("disable", "Codex"))
        shared_link = self.project / "AGENTS.md"
        self.assertTrue(shared_link.is_symlink())
        self.assertEqual(shared_link.resolve(), self.source)

        self.assert_success(self.run_ctx("disable", "Antigravity"))
        self.assertFalse(shared_link.exists())
        self.assertFalse(shared_link.is_symlink())

    def test_sync_preserves_directory_at_enabled_target(self):
        self.prepare_source()
        directory = self.project / "AGENTS.md"
        directory.mkdir()
        sentinel = directory / "local-rules.md"
        sentinel.write_text("Keep directory contents.\n", encoding="utf-8")

        result = self.run_ctx("sync")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(directory.iterdir()), [sentinel])
        self.assertFalse((self.project / "CLAUDE.md").exists())
        self.assertIn("AGENTS.md", result.stdout + result.stderr)

    def test_sync_rejects_source_as_enabled_target(self):
        self.prepare_source()
        self.config["agent_rules"] = [
            {
                "name": "Self target",
                "path": "sample-context/../sample-context/AGENT_RULES.md",
                "enabled": True,
            }
        ]
        self.write_config()

        result = self.run_ctx("sync")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.source.is_symlink())
        self.assertEqual(self.source.read_text(encoding="utf-8"), "# Shared project rules\n")
        self.assertIn("source", (result.stdout + result.stderr).lower())

    def test_disabled_source_symlink_is_preserved(self):
        self.prepare_source()
        original = self.source.with_name("original-rules.md")
        self.source.rename(original)
        self.source.symlink_to(original.name)
        self.config["agent_rules"] = [
            {
                "name": "Disabled source",
                "path": "sample-context/./AGENT_RULES.md",
                "enabled": False,
            }
        ]
        self.write_config()

        result = self.run_ctx("sync")

        self.assert_success(result)
        self.assertTrue(self.source.is_symlink())
        self.assertEqual(os.readlink(self.source), original.name)
        self.assertEqual(original.read_text(encoding="utf-8"), "# Shared project rules\n")

    def test_sync_rejects_source_through_directory_symlink_parent(self):
        self.prepare_source()
        original = self.source.with_name("original-rules.md")
        self.source.rename(original)
        self.source.symlink_to(original.name)
        (self.source.parent / "sub").mkdir()
        (self.project / "alias").symlink_to("sample-context/sub", target_is_directory=True)
        self.config["agent_rules"] = [
            {"name": "Source alias", "path": "alias/../AGENT_RULES.md", "enabled": True}
        ]
        self.write_config()

        result = self.run_ctx("sync")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(os.readlink(self.source), original.name)
        self.assertEqual(self.source.read_text(encoding="utf-8"), "# Shared project rules\n")
        self.assertIn("alias/../AGENT_RULES.md", result.stdout + result.stderr)

    def test_disabled_source_through_directory_symlink_parent_is_preserved(self):
        self.prepare_source()
        original = self.source.with_name("original-rules.md")
        self.source.rename(original)
        self.source.symlink_to(original.name)
        (self.source.parent / "sub").mkdir()
        (self.project / "alias").symlink_to("sample-context/sub", target_is_directory=True)
        # Collapsing '..' first finds this different entry pointing to the source.
        (self.project / "AGENT_RULES.md").symlink_to("sample-context/AGENT_RULES.md")
        self.config["agent_rules"] = [
            {"name": "Source alias", "path": "alias/../AGENT_RULES.md", "enabled": False}
        ]
        self.write_config()

        result = self.run_ctx("sync")

        self.assert_success(result)
        self.assertTrue(self.source.is_symlink())
        self.assertEqual(os.readlink(self.source), original.name)
        self.assertEqual(self.source.read_text(encoding="utf-8"), "# Shared project rules\n")

    def test_sync_preserves_enabled_link_in_source_resolution_chain(self):
        self.source.parent.mkdir(parents=True)
        original = self.project / "original-rules.md"
        original.write_text("# Original project rules\n", encoding="utf-8")
        link = self.project / "RULES.md"
        link.symlink_to(original.name)
        self.source.symlink_to("../RULES.md")
        self.config["agent_rules"] = [
            {"name": "Source chain", "path": "RULES.md", "enabled": True}
        ]
        self.write_config()

        result = self.run_ctx("sync")

        self.assert_success(result)
        self.assertEqual(os.readlink(link), original.name)
        self.assertEqual(self.source.read_text(encoding="utf-8"), "# Original project rules\n")

    def test_sync_preserves_disabled_link_in_source_resolution_chain(self):
        self.source.parent.mkdir(parents=True)
        original = self.project / "original-rules.md"
        original.write_text("# Original project rules\n", encoding="utf-8")
        link = self.project / "RULES.md"
        link.symlink_to(original.name)
        self.source.symlink_to("../RULES.md")
        self.config["agent_rules"] = [
            {"name": "Source chain", "path": "RULES.md", "enabled": False}
        ]
        self.write_config()

        result = self.run_ctx("sync")

        self.assert_success(result)
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), original.name)
        self.assertEqual(self.source.read_text(encoding="utf-8"), "# Original project rules\n")


if __name__ == "__main__":
    unittest.main()
