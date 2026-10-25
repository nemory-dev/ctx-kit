"""Real-CLI regressions for quoted and non-ASCII filesystem paths."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class PathPortabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-path-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        # Ignore the caller's repository, identity, signing and hook settings.
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_")
        }
        self.env.update({
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "ctx-kit test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "ctx-kit test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        self.empty_template = self.base / "empty-git-template"
        self.empty_template.mkdir()
        self.env["GIT_TEMPLATE_DIR"] = str(self.empty_template)

    def install(self, name="project's space 한글", scripts=False, source=None):
        self.project = self.base / name
        self.script = self.project / ("scripts/ctx.sh" if scripts else "ctx.sh")
        self.script.parent.mkdir(parents=True)
        shutil.copy2(REPO / "ctx.sh", self.script)
        self.config = json.loads((REPO / "ctx.config.json").read_text(encoding="utf-8"))
        if source is not None:
            self.config["source"] = source
        self.write_config()
        self.context = self.project / Path(self.config["source"]).parent

    def write_config(self):
        (self.project / "ctx.config.json").write_text(
            json.dumps(self.config, ensure_ascii=False), encoding="utf-8"
        )

    def run_ctx(self, *args):
        result = subprocess.run(
            ["bash", str(self.script), *args], cwd=self.project, env=self.env,
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("SyntaxError", result.stderr)
        return result

    def initialize(self):
        self.run_ctx("init", "--no-hook", "--no-backfill")

    def git(self, *args):
        result = subprocess.run(
            ["git", *args], cwd=self.project, env=self.env,
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def entries(self, path):
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]

    def test_project_path_supports_root_and_scripts_installations(self):
        for scripts in (False, True):
            with self.subTest(scripts=scripts):
                self.install(name="project's space 한글-{}".format(scripts), scripts=scripts)
                self.initialize()
                source = self.context / "AGENT_RULES.md"
                self.assertEqual((self.project / "CLAUDE.md").resolve(), source)
                self.assertIn("Source file exists", self.run_ctx("status").stdout)
                self.assertIn("Claude", self.run_ctx("list").stdout)
                self.run_ctx("sync")
                self.run_ctx("disable", "Claude")
                self.assertFalse((self.project / "CLAUDE.md").is_symlink())
                self.run_ctx("enable", "Claude")
                self.assertEqual((self.project / "CLAUDE.md").resolve(), source)
                self.assertIn("## [MASTER_PLAN]", self.run_ctx("export").stdout)

    def test_custom_source_and_agent_link_keep_literal_path_characters(self):
        self.install(name="plain-project", source="context's 한글 folder/AGENT_RULES.md")
        agent = {"name": "Claude's 한글", "path": "agent's 한글 folder/rules.md", "enabled": True}
        self.config["agent_rules"] = [agent]
        self.write_config()
        self.initialize()
        link = self.project / agent["path"]
        self.assertEqual(link.resolve(), self.context / "AGENT_RULES.md")
        self.assertIn("context's 한글 folder/", link.read_text(encoding="utf-8"))
        self.run_ctx("disable", agent["name"])
        self.assertFalse(link.is_symlink())
        self.run_ctx("enable", agent["name"])
        self.assertEqual(link.resolve(), self.context / "AGENT_RULES.md")
        self.assertIn(agent["path"], self.run_ctx("status").stdout)

    def test_generate_collects_quoted_filename_and_writes_quoted_output(self):
        # A plain root isolates interpolation of the collected filename.
        self.install(name="plain-generator")
        filename = "input's 한글 folder/spec's notes.md"
        output = "generated's 한글 folder/project's context.md"
        source = self.project / filename
        source.parent.mkdir()
        source.write_text("Literal path content 한글\n", encoding="utf-8")
        self.config["generate"] = {"project": {"collect": [filename], "output": output}}
        self.write_config()
        self.run_ctx("generate", "project")
        generated = (self.project / output).read_text(encoding="utf-8")
        self.assertIn("## [{}]".format(filename), generated)
        self.assertIn("Literal path content 한글", generated)

    def test_log_and_archive_preserve_data_beneath_quoted_paths(self):
        self.install(source="context's 한글 folder/AGENT_RULES.md")
        self.initialize()
        summary = "검증한 작업's 결과"
        self.run_ctx("log", "--summary", summary, "--files", "app's 한글.txt")
        timeline = self.context / "work-log/timeline.jsonl"
        original = self.entries(timeline)
        self.assertEqual(original[0]["summary"], summary)
        self.assertEqual(original[0]["files"], ["app's 한글.txt"])
        self.assertEqual(json.loads(self.run_ctx("timeline", "--json").stdout), original)
        plan = self.context / "MASTER_PLAN.md"
        plan.write_text("# Plan\n\n- [x] 완료한 작업\n- [ ] 다음 작업\n", encoding="utf-8")
        self.run_ctx("archive", "--keep", "0", "--no-decisions")
        archive = self.context / "archive"
        monthly = archive / ("timeline-" + original[0]["createdAt"][:7] + ".jsonl")
        self.assertEqual(self.entries(monthly), original)
        self.assertEqual(self.entries(timeline), [])
        self.assertNotIn("완료한 작업", plan.read_text(encoding="utf-8"))
        self.assertIn("다음 작업", plan.read_text(encoding="utf-8"))
        self.assertIn("완료한 작업", (archive / "completed-tasks.md").read_text(encoding="utf-8"))
        self.assertIn(summary, self.run_ctx("export", "--all").stdout)

    def test_installed_hook_autologs_real_commit_in_quoted_scripts_project(self):
        self.install(scripts=True, source="context's 한글 folder/AGENT_RULES.md")
        self.initialize()
        self.git("init", "--quiet")
        app = self.project / "app.txt"
        app.write_text("before\n", encoding="utf-8")
        self.git("add", "--", "app.txt")
        self.git("commit", "--quiet", "-m", "fixture")
        self.run_ctx("hook", "install")
        hook = self.project / ".git/hooks/pre-commit"
        self.assertTrue(os.access(hook, os.X_OK))
        self.assertIn("Installed", self.run_ctx("hook", "status").stdout)
        context_head = self.git("-C", str(self.context), "rev-parse", "HEAD")
        app.write_text("after\n", encoding="utf-8")
        self.git("add", "--", "app.txt")
        self.git("commit", "--quiet", "-m", "quoted path change")
        timeline = self.context / "work-log/timeline.jsonl"
        logged = self.entries(timeline)
        self.assertEqual(len(logged), 1)
        self.assertEqual(logged[0]["files"], ["app.txt"])
        self.assertEqual(logged[0]["commit"], "pending")
        self.assertNotEqual(self.git("-C", str(self.context), "rev-parse", "HEAD"), context_head)
        saved = self.git("-C", str(self.context), "show", "HEAD:work-log/timeline.jsonl")
        self.assertEqual([json.loads(line) for line in saved.splitlines()], logged)
        self.assertEqual(self.git("ls-tree", "-r", "--name-only", "HEAD"), "app.txt")
        self.run_ctx("hook", "uninstall")
        self.assertFalse(hook.exists())
        self.assertIn("Not installed", self.run_ctx("hook", "status").stdout)
        config = json.loads((self.project / "ctx.config.json").read_text(encoding="utf-8"))
        self.assertFalse(config["git_sync"]["enabled"])


if __name__ == "__main__":
    unittest.main()
