"""Portable Python discovery, version validation, and runtime-path regressions."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")


class PythonRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-runtime-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / "project"
        self.project.mkdir()
        self.script = self.project / "ctx.sh"
        shutil.copy2(REPO / "ctx.sh", self.script)
        # Keep system Python installations out of discovery and ensure the
        # selected executable can live in a path with spaces and apostrophes.
        self.bin = self.root / "runtime bin's"
        self.bin.mkdir()
        for name in (
            "awk", "basename", "cat", "cp", "date", "dirname", "find",
            "git", "grep", "head", "ln", "mkdir", "rm", "sed", "sort",
            "tr", "wc",
        ):
            executable = shutil.which(name)
            if executable:
                (self.bin / name).symlink_to(executable)
        self.calls = self.root / "runtime-calls.txt"
        # Git must not inherit the caller's repository, index or configuration.
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_")
        }
        self.env.update(
            PATH=str(self.bin),
            CTX_TEST_RUNTIME_CALLS=str(self.calls),
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_SYSTEM=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            PYTHONDONTWRITEBYTECODE="1",
        )

    def runtime(self, name, version=None, broken=False, crlf=False):
        """Create an executable, delegating supported execution to real Python."""
        lines = [
            "#!/bin/sh",
            'printf "%s\\n" ' + shlex.quote(name) + ' >> "$CTX_TEST_RUNTIME_CALLS"',
        ]
        if name == "py":
            # Reject a launcher used without its required Python 3 selector.
            lines.extend(['[ "${1:-}" = "-3" ] || exit 89', "shift"])
        if broken:
            lines.append("exit 126")
        else:
            if version or crlf:
                modules = self.root / (name + "-startup")
                modules.mkdir()
                startup = "import sys\n"
                if version:
                    # Arbitrary code still executes successfully. Only the
                    # runtime version differs, so a probe must check its value.
                    parts = tuple(int(part) for part in version.split("."))
                    startup += (
                        "from collections import namedtuple\n"
                        "sys.version_info = namedtuple('version_info', "
                        "'major minor micro releaselevel serial')"
                        + repr(parts + ("final", 0)) + "\n"
                    )
                if crlf:
                    # Native Windows Python translates stdout newlines even
                    # when the parent shell expects POSIX path delimiters.
                    startup += "sys.stdout.reconfigure(newline='\\r\\n')\n"
                (modules / "sitecustomize.py").write_text(
                    startup,
                    encoding="utf-8",
                )
                lines.append("export PYTHONPATH=" + shlex.quote(str(modules)))
            lines.append("exec " + shlex.quote(sys.executable) + ' "$@"')
        path = self.bin / name
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        path.chmod(0o755)

    def run_ctx(self, *args):
        return subprocess.run(
            [BASH, str(self.script), *args],
            cwd=self.project,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def selected_calls(self):
        return self.calls.read_text(encoding="utf-8").splitlines() if self.calls.exists() else []

    def initialize(self):
        result = self.run_ctx("init", "--no-hook", "--no-backfill")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.project / "sample-context/AGENT_RULES.md").is_file())
        return result

    def assert_no_initialization(self):
        self.assertEqual(sorted(path.name for path in self.project.iterdir()), ["ctx.sh"])

    def test_python3_is_preferred_over_python_and_launcher(self):
        for name in ("python3", "python", "py"):
            self.runtime(name)
        self.initialize()
        self.assertTrue(self.selected_calls())
        self.assertEqual(set(self.selected_calls()), {"python3"})

    def test_python_is_used_when_python3_is_missing(self):
        self.runtime("python")
        self.runtime("py")
        self.initialize()
        self.assertEqual(set(self.selected_calls()), {"python"})

    def test_py_launcher_uses_python3_selector_and_preserves_arguments(self):
        self.runtime("py")
        self.initialize()
        summary = "launcher's summary with spaces and 한글"
        recorded = self.run_ctx("log", "--summary", summary)
        self.assertEqual(recorded.returncode, 0, recorded.stdout + recorded.stderr)
        readback = self.run_ctx("timeline", "--limit", "1", "--json")
        self.assertEqual(readback.returncode, 0, readback.stdout + readback.stderr)
        self.assertEqual(json.loads(readback.stdout)[0]["summary"], summary)
        self.assertEqual(set(self.selected_calls()), {"py"})

    def test_python2_and_python36_are_skipped_before_launcher(self):
        self.runtime("python3", version="3.6.15")
        self.runtime("python", version="2.7.18")
        self.runtime("py")
        self.initialize()
        calls = self.selected_calls()
        self.assertIn("python3", calls)
        self.assertIn("python", calls)
        self.assertIn("py", calls)
        self.assertLess(calls.index("python3"), calls.index("python"))
        self.assertLess(calls.index("python"), calls.index("py"))

    def test_unusable_python3_falls_back_to_python(self):
        self.runtime("python3", broken=True)
        self.runtime("python")
        self.initialize()
        calls = self.selected_calls()
        self.assertEqual(calls[0], "python3")
        self.assertIn("python", calls)

    def test_python37_is_accepted_at_the_minimum_version_boundary(self):
        self.runtime("python3", version="3.7.0")
        self.initialize()
        self.assertEqual(set(self.selected_calls()), {"python3"})

    def test_missing_python_fails_before_creating_config_or_context(self):
        result = self.run_ctx("init", "--no-hook", "--no-backfill")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("python", result.stderr.lower())
        self.assertIn("3.7", result.stderr)
        self.assert_no_initialization()

    def test_all_invalid_runtimes_fail_before_creating_config_or_context(self):
        self.runtime("python3", version="3.6.15")
        self.runtime("python", version="2.7.18")
        self.runtime("py", broken=True)
        result = self.run_ctx("init", "--no-hook", "--no-backfill")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("python", result.stderr.lower())
        self.assertIn("3.7", result.stderr)
        self.assert_no_initialization()

    def test_help_and_version_work_without_python(self):
        for command in ("help", "--help", "version"):
            with self.subTest(command=command):
                result = self.run_ctx(command)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("ctx", result.stdout)
        self.assertEqual(self.selected_calls(), [])
        self.assert_no_initialization()

    def test_list_fails_without_a_supported_python(self):
        config = self.project / "ctx.config.json"
        shutil.copy2(REPO / "ctx.config.json", config)
        original = config.read_bytes()
        for runtime in ("missing", "unsupported"):
            with self.subTest(runtime=runtime):
                if runtime == "unsupported":
                    self.runtime("python3", version="3.6.15")
                result = self.run_ctx("list")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("python", result.stderr.lower())
                self.assertEqual(config.read_bytes(), original)

    def test_crlf_launcher_output_supports_init_and_generate(self):
        self.runtime("py", crlf=True)
        self.initialize()
        config_path = self.project / "ctx.config.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        config["generate"]["windows"] = {
            "output": "generated/windows-context.md",
            "collect": ["first.md", "second.md"],
        }
        config_path.write_text(json.dumps(config), encoding="utf-8")
        for name in ("first.md", "second.md"):
            (self.project / name).write_text("Content of " + name + "\n", encoding="utf-8")
        result = self.run_ctx("generate", "windows")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        bundle = (self.project / "generated/windows-context.md").read_text(encoding="utf-8")
        for name in ("first.md", "second.md"):
            self.assertIn("Content of " + name, bundle)
        self.assertFalse(any("\r" in str(path) for path in self.project.rglob("*")))

    def test_crlf_launcher_output_preserves_hook_auto_logging(self):
        self.runtime("py", crlf=True)
        (self.bin / "bash").symlink_to(BASH)
        templates = self.root / "empty-git-templates"
        templates.mkdir()
        self.env.update(
            GIT_TEMPLATE_DIR=str(templates),
            GIT_AUTHOR_NAME="ctx-kit runtime test",
            GIT_AUTHOR_EMAIL="runtime@example.invalid",
            GIT_COMMITTER_NAME="ctx-kit runtime test",
            GIT_COMMITTER_EMAIL="runtime@example.invalid",
        )

        def git(*args):
            result = subprocess.run(
                ["git", *args], cwd=self.project, env=self.env,
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

        self.initialize()
        git("init", "--quiet")
        installed = self.run_ctx("hook", "install")
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        status = self.run_ctx("hook", "status")
        self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
        self.assertIn("(auto_log: True)", status.stdout)
        (self.project / "app.txt").write_text("Committed content\n", encoding="utf-8")
        git("add", "app.txt")
        git("commit", "--quiet", "--no-gpg-sign", "-m", "Verify CRLF launcher hook")
        self.assertTrue(
            (self.project / "sample-context/work-log/timeline.jsonl").is_file(),
            "CRLF launcher output must not silently disable hook auto logging",
        )
        readback = self.run_ctx("timeline", "--limit", "1", "--json")
        self.assertEqual(readback.returncode, 0, readback.stdout + readback.stderr)
        entries = json.loads(readback.stdout)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["files"], ["app.txt"])
        self.assertIn("Pre-commit auto-log", entries[0]["summary"])
        local_log = git(
            "-C", str(self.project / "sample-context"),
            "show", "HEAD:work-log/timeline.jsonl",
        )
        self.assertEqual(json.loads(local_log)["id"], entries[0]["id"])


if __name__ == "__main__":
    unittest.main()
