"""Real Git checks for literal, root-scoped context ignore rules."""

import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class HookIgnoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-hook-ignore-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        templates = self.base / "empty-template"
        templates.mkdir()
        self.env.update(
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_SYSTEM=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TEMPLATE_DIR=str(templates),
            GIT_AUTHOR_NAME="ctx-kit test",
            GIT_AUTHOR_EMAIL="test@example.invalid",
            GIT_COMMITTER_NAME="ctx-kit test",
            GIT_COMMITTER_EMAIL="test@example.invalid",
            PYTHONDONTWRITEBYTECODE="1",
        )

    def prepare(self, name, context="sample-context", scripts=False):
        self.project = self.base / (name + "'s 한글 project")
        self.script = self.project / ("scripts/ctx.sh" if scripts else "ctx.sh")
        self.script.parent.mkdir(parents=True)
        shutil.copy2(REPO / "ctx.sh", self.script)
        self.context_name = context
        self.context = self.project / context
        self.context.mkdir(parents=True)
        (self.context / "AGENT_RULES.md").write_text("# Private rules\n", encoding="utf-8")
        self.config = self.project / "ctx.config.json"
        self.config.write_text(json.dumps({
            "source": context + "/AGENT_RULES.md",
            "agent_rules": [],
            "git_sync": {"enabled": False, "auto_log": False},
        }, ensure_ascii=False), encoding="utf-8")
        self.ignore = self.project / ".gitignore"
        self.assert_success(self.command("git", "init", "--quiet"))

    def command(self, *args, env=None):
        return subprocess.run(
            list(args), cwd=self.project, env=env or self.env,
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20,
        )

    def run_ctx(self, *args, env=None):
        return self.command("/bin/bash", str(self.script), *args, env=env)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def assert_ignored(self, path):
        self.assert_success(self.command("git", "check-ignore", "-q", "--", path))

    def assert_not_ignored(self, path):
        result = self.command("git", "check-ignore", "-q", "--", path)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def write_public_file(self, relative):
        path = self.project / relative / "public.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("Public project data\n", encoding="utf-8")
        return path.relative_to(self.project).as_posix()

    def snapshot(self):
        entries = {}
        for path in sorted(self.project.rglob("*")):
            info = path.lstat()
            content = os.readlink(path) if path.is_symlink() else (
                path.read_bytes() if path.is_file() else None
            )
            entries[str(path.relative_to(self.project))] = (info.st_mode, content)
        return entries

    def test_special_context_names_are_ignored_without_matching_other_paths(self):
        cases = (
            ("ctx[ab]", "ctxa"),
            ("ctx?notes", "ctxXnotes"),
            ("ctx*notes", "ctxXnotes"),
            ("#context", "other-context"),
            ("!context", "other-context"),
            (r"ctx\notes", "ctxnotes"),
            ("context\\", "context"),
            ("ctx%snotes", "ctxnotes"),
            ("context%", "context"),
            ("context's 한글 space", "other-context"),
            ("context ", "context"),
            ("-context", "other-context"),
            ("nested folder/ctx[ab]", "nested folder/ctxa"),
        )
        for index, (context, lookalike) in enumerate(cases):
            with self.subTest(context=context):
                self.prepare("special-" + str(index), context=context)
                public = self.write_public_file(lookalike)
                nested = self.write_public_file("unrelated/" + context)

                self.assert_success(self.run_ctx("hook", "install"))

                self.assert_ignored(context + "/AGENT_RULES.md")
                self.assert_not_ignored(public)
                self.assert_not_ignored(nested)

    def test_plain_context_rule_is_anchored_at_project_root(self):
        self.prepare("root-anchor", context="local-context")
        nested = self.write_public_file("unrelated/local-context")

        self.assert_success(self.run_ctx("hook", "install"))

        self.assert_ignored("local-context/AGENT_RULES.md")
        self.assert_not_ignored(nested)

    def test_dot_components_in_context_path_are_normalized(self):
        for index, context in enumerate(("./local-context", "nested/./ctx[ab]")):
            with self.subTest(context=context):
                self.prepare("dot-components-" + str(index), context=context)
                nested = self.write_public_file("unrelated/" + context)

                self.assert_success(self.run_ctx("hook", "install"))

                self.assert_ignored(context + "/AGENT_RULES.md")
                self.assert_not_ignored(nested)

    def test_special_context_is_not_added_to_parent_index(self):
        self.prepare("index", context="ctx[ab]")
        (self.project / "public.txt").write_text("Public\n", encoding="utf-8")
        self.assert_success(self.run_ctx("hook", "install"))

        self.assert_success(self.command("git", "add", "--", "."))

        staged = self.assert_success(self.command("git", "ls-files", "-z")).stdout.split("\0")
        self.assertEqual(sorted(filter(None, staged)),
                         [".gitignore", "ctx.config.json", "ctx.sh", "public.txt"])

    def test_reinstall_preserves_existing_ignore_bytes_and_permissions(self):
        for scripts in (False, True):
            with self.subTest(scripts=scripts):
                self.prepare("reinstall-" + str(scripts), context="ctx[ab]", scripts=scripts)
                original = b"# User rules\r\ncache/\r\nlast-without-newline"
                self.ignore.write_bytes(original)
                self.ignore.chmod(0o640)
                self.assert_success(self.run_ctx("hook", "install"))
                first = self.ignore.read_bytes()
                self.assertTrue(first.startswith(original))

                self.assert_success(self.run_ctx("hook", "install"))

                self.assertEqual(self.ignore.read_bytes(), first)
                self.assertEqual(stat.S_IMODE(self.ignore.stat().st_mode), 0o640)
                self.assert_ignored("ctx[ab]/AGENT_RULES.md")

    def test_existing_gitignore_or_info_exclude_rule_is_preserved(self):
        for location in (".gitignore", ".git/info/exclude"):
            with self.subTest(location=location):
                self.prepare("existing-" + location.replace("/", "-"), context="ctx[ab]")
                path = self.project / location
                path.parent.mkdir(parents=True, exist_ok=True)
                original = b"# Existing user rule\n/ctx\\[ab\\]/\n"
                path.write_bytes(original)
                path.chmod(0o640)

                self.assert_success(self.run_ctx("hook", "install"))

                self.assertEqual(path.read_bytes(), original)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
                if location != ".gitignore":
                    self.assertFalse(self.ignore.exists())
                self.assert_ignored("ctx[ab]/AGENT_RULES.md")

    def test_leading_dash_context_is_reported_as_ignored(self):
        self.prepare("dash-status", context="-context")
        self.assert_success(self.run_ctx("hook", "install"))

        result = self.assert_success(self.run_ctx("hook", "status"))

        self.assertIn("Ignored", result.stdout)
        self.assertNotIn("Not ignored", result.stdout)

    def test_line_break_context_is_rejected_before_installation_changes(self):
        for index, context in enumerate(("context\n*", "context\rname", "context\n", "context\n\n")):
            with self.subTest(context=context):
                self.prepare("line-break-" + str(index), context=context)
                self.ignore.write_bytes(b"# User ignore rules\n")
                before = self.snapshot()

                result = self.run_ctx("hook", "install")

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(result.stderr.strip())
                self.assertEqual(self.snapshot(), before)
                self.assertNotIn("Git sync hook setup complete!", result.stdout)

    def test_git_check_failure_does_not_change_installation(self):
        self.prepare("check-failure")
        self.ignore.write_bytes(b"# User ignore rules\n")
        before = self.snapshot()
        binaries = self.base / "fault-bin"
        binaries.mkdir()
        wrapper = binaries / "git"
        wrapper.write_text(
            '#!/bin/sh\nfor argument do\n'
            '  if [ "$argument" = "check-ignore" ]; then\n'
            '    echo "injected git check-ignore failure" >&2\n    exit 128\n  fi\ndone\n'
            'exec ' + shlex.quote(shutil.which("git")) + ' "$@"\n', encoding="utf-8"
        )
        wrapper.chmod(0o755)
        env = dict(self.env, PATH=str(binaries) + os.pathsep + self.env.get("PATH", ""))

        result = self.run_ctx("hook", "install", env=env)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("check-ignore", result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertNotIn("Git sync hook setup complete!", result.stdout)


if __name__ == "__main__":
    unittest.main()
