"""CLI contract for the two-file copied viewer installation."""

import json
import shutil

from viewer_support import BaseViewCase


class ViewCommandTests(BaseViewCase):
    def test_view_help_does_not_write(self):
        before = self.source_snapshot()
        result = self.run_ctx("view", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--output", result.stdout)
        self.assertEqual(self.source_snapshot(), before)
        self.assertFalse(self.output.exists())
        self.assertFalse((self.context / "work-log").exists())

    def test_view_rejects_missing_output_value(self):
        for args in (("--output",), ("--output", ""), ("--output", "--open")):
            result = self.run_ctx("view", *args)
            self.assertEqual(result.returncode, 1)
            self.assertIn("--output", result.stderr)
        self.assertFalse(self.output.exists())

    def test_view_rejects_unknown_option(self):
        for option in ("--force", "unexpected"):
            result = self.run_ctx("view", option)
            self.assertEqual(result.returncode, 1)
            self.assertIn(option, result.stderr)

    def test_view_requires_context(self):
        shutil.rmtree(self.context)
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 1)
        self.assertIn("init", result.stdout + result.stderr)
        self.assertFalse(self.context.exists())

    def test_view_requires_config(self):
        (self.project / "ctx.config.json").unlink()
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 1)
        self.assertIn("init", result.stdout + result.stderr)
        self.assertFalse(self.output.exists())

    def test_view_invalid_config_reports_error_without_traceback(self):
        for content in ("[]", '{"source":[]}', '{"broken":',
                        '{"source":' + "[" * 1100 + "0" + "]" * 1100 + "}"):
            with self.subTest(content=content[:30]):
                (self.project / "ctx.config.json").write_text(content, encoding="utf-8")
                result = self.run_ctx("view")
                self.assertEqual(result.returncode, 1)
                self.assertIn("Error:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse(self.output.exists())

    def test_view_standalone_copy(self):
        before = self.source_snapshot()
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read_view_model()["viewModelVersion"], 1)
        self.assertEqual(self.source_snapshot(), before)
        self.assertIn("view.html", result.stdout)

    def test_view_scripts_install_and_custom_context(self):
        scripts = self.project / "scripts"
        scripts.mkdir()
        self.script = self.script.rename(scripts / "ctx.sh")
        self.context = self.context.rename(self.project / "custom-context")
        (self.project / "ctx.config.json").write_text(json.dumps({
            "source": "custom-context/AGENT_RULES.md", "agent_rules": [],
        }), encoding="utf-8")
        result = self.run_ctx("view", "--output", "reports/context.html")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read_view_model(self.project / "reports/context.html")
                         ["project"]["contextPath"], "custom-context")

    def test_view_help_without_config_or_python(self):
        (self.project / "ctx.config.json").unlink()
        self.env["PATH"] = "/usr/bin:/bin"
        result = self.run_ctx("view", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--open", result.stdout)

    def test_view_resolves_output_from_project_root(self):
        target = self.project / "reports/absolute.html"
        result = self.run_ctx("view", "--output", str(target))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read_view_model(target)["viewModelVersion"], 1)
