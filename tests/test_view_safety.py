"""Output preservation and opt-in browser launch through the copied CLI."""

import os
from pathlib import Path
import stat
import sys
import tempfile
import shlex

from viewer_support import BaseViewCase


MARKER = "<!-- ctx-kit-viewer:1 -->\n"


class ViewSafetyTests(BaseViewCase):
    def seed_output(self):
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_text(MARKER + "previous snapshot\n", encoding="utf-8")
        return self.output.read_bytes()

    def inject_python(self, source):
        directory = self.project / "fault-bin"
        directory.mkdir(exist_ok=True)
        (directory / "sitecustomize.py").write_text(source, encoding="utf-8")
        self.env["PYTHONPATH"] = str(directory)

    def assert_preserved_failure(self, result, before):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.output.read_bytes(), before)
        self.assertFalse(list(self.output.parent.glob(".ctx-view-*")))

    def test_new_output_is_private_and_sources_are_preserved(self):
        before = self.source_snapshot()
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.output.read_text(encoding="utf-8").startswith(MARKER))
        if os.name != "nt":
            self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertEqual(self.source_snapshot(), before)

    def test_generated_output_can_be_replaced_and_keeps_permissions(self):
        before = self.seed_output()
        self.output.chmod(0o640)
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotEqual(self.output.read_bytes(), before)
        if os.name != "nt":
            self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o640)

    def test_existing_user_html_is_preserved(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_text("<html>my report</html>\n", encoding="utf-8")
        self.assert_preserved_failure(self.run_ctx("view"), self.output.read_bytes())

    def test_output_symlink_is_preserved(self):
        self.output.parent.mkdir(parents=True)
        target = self.project / "private.html"
        target.write_text(MARKER + "private\n", encoding="utf-8")
        self.output.symlink_to(target)
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(target.read_text(encoding="utf-8"), MARKER + "private\n")

    def test_broken_output_symlink_is_preserved(self):
        self.output.parent.mkdir(parents=True)
        self.output.symlink_to(self.project / "missing.html")
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(self.output.is_symlink())
        self.assertFalse((self.project / "missing.html").exists())

    def test_directory_and_fifo_output_are_rejected(self):
        self.output.mkdir(parents=True)
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(self.output.is_dir())
        self.output.rmdir()
        if hasattr(os, "mkfifo"):
            os.mkfifo(str(self.output))
            result = self.run_ctx("view")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertTrue(stat.S_ISFIFO(self.output.lstat().st_mode))

    def test_hardlinked_output_is_preserved(self):
        before = self.seed_output()
        alias = self.project / "other.html"
        os.link(str(self.output), str(alias))
        self.assert_preserved_failure(self.run_ctx("view"), before)
        self.assertEqual(alias.read_bytes(), before)

    def test_output_outside_project_and_wrong_extension_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="ctx-view-outside-") as directory:
            outside = Path(directory) / "outside.html"
            for target in (str(outside), "../escaped.html", "reports/report.md"):
                result = self.run_ctx("view", "--output", target)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertFalse(outside.exists())
        self.assertFalse((self.project / "reports").exists())

    def test_parent_symlink_cannot_escape_project(self):
        with tempfile.TemporaryDirectory(prefix="ctx-view-outside-") as directory:
            (self.project / "reports").symlink_to(directory, target_is_directory=True)
            result = self.run_ctx("view", "--output", "reports/view.html")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertFalse((Path(directory) / "view.html").exists())

    def test_parent_symlink_inside_project_is_resolved(self):
        (self.project / "reports").mkdir()
        (self.project / "alias").symlink_to("reports", target_is_directory=True)
        result = self.run_ctx("view", "--output", "alias/view.html")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read_view_model(self.project / "reports/view.html")
                         ["viewModelVersion"], 1)

    def test_replace_failure_preserves_output_and_removes_temporary(self):
        before = self.seed_output()
        self.inject_python(
            "import os\n"
            "original = os.replace\n"
            "def replace(source, destination, *args, **kwargs):\n"
            "    if str(destination).endswith('view.html'):\n"
            "        raise OSError('injected viewer replace failure')\n"
            "    return original(source, destination, *args, **kwargs)\n"
            "os.replace = replace\n")
        result = self.run_ctx("view")
        self.assert_preserved_failure(result, before)
        self.assertIn("injected viewer replace failure", result.stderr)

    def test_temporary_fsync_failure_preserves_output(self):
        before = self.seed_output()
        self.inject_python(
            "import os, stat\n"
            "original = os.fsync\n"
            "def fsync(fd):\n"
            "    if stat.S_ISREG(os.fstat(fd).st_mode):\n"
            "        raise OSError('injected viewer write sync failure')\n"
            "    return original(fd)\n"
            "os.fsync = fsync\n")
        result = self.run_ctx("view")
        self.assert_preserved_failure(result, before)
        self.assertIn("injected viewer write sync failure", result.stderr)

    def test_temporary_write_failure_preserves_output(self):
        before = self.seed_output()
        self.inject_python(
            "import os, tempfile\n"
            "original_mkstemp, original_fdopen = tempfile.mkstemp, os.fdopen\n"
            "staging = set()\n"
            "def mkstemp(*args, **kwargs):\n"
            "    fd, path = original_mkstemp(*args, **kwargs)\n"
            "    if os.path.basename(path).startswith('.ctx-view-'):\n"
            "        staging.add(fd)\n"
            "    return fd, path\n"
            "class WriteFault:\n"
            "    def __init__(self, stream): self.stream = stream\n"
            "    def __enter__(self): self.stream.__enter__(); return self\n"
            "    def __exit__(self, *args): return self.stream.__exit__(*args)\n"
            "    def write(self, text): raise OSError('injected viewer write failure')\n"
            "def fdopen(fd, *args, **kwargs):\n"
            "    stream = original_fdopen(fd, *args, **kwargs)\n"
            "    return WriteFault(stream) if fd in staging else stream\n"
            "tempfile.mkstemp, os.fdopen = mkstemp, fdopen\n")
        result = self.run_ctx("view")
        self.assert_preserved_failure(result, before)
        self.assertIn("injected viewer write failure", result.stderr)

    def test_output_changed_during_collection_is_not_overwritten(self):
        self.seed_output()
        concurrent = MARKER + "changed while collecting\n"
        self.inject_python(
            "import os, subprocess\n"
            "original = subprocess.run\n"
            "changed = False\n"
            "def run(args, *positional, **keywords):\n"
            "    global changed\n"
            "    if (not changed and isinstance(args, (list, tuple)) and args\n"
            "            and os.path.basename(args[0]) == 'git'):\n"
            "        changed = True\n"
            "        with open(" + repr(str(self.output)) + ", 'w') as stream:\n"
            "            stream.write(" + repr(concurrent) + ")\n"
            "    return original(args, *positional, **keywords)\n"
            "subprocess.run = run\n")
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), concurrent)
        self.assertFalse(list(self.output.parent.glob(".ctx-view-*")))

    def test_concurrent_output_change_is_not_overwritten(self):
        self.seed_output()
        concurrent = MARKER + "concurrent writer\n"
        self.inject_python(
            "import os, stat\n"
            "original = os.fsync\n"
            "def fsync(fd):\n"
            "    if stat.S_ISREG(os.fstat(fd).st_mode):\n"
            "        with open(" + repr(str(self.output)) + ", 'w') as stream:\n"
            "            stream.write(" + repr(concurrent) + ")\n"
            "    return original(fd)\n"
            "os.fsync = fsync\n")
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), concurrent)
        self.assertFalse(list(self.output.parent.glob(".ctx-view-*")))

    def test_directory_sync_failure_reports_saved_output(self):
        before = self.seed_output()
        self.inject_python(
            "import os, stat\n"
            "original_replace, original_sync = os.replace, os.fsync\n"
            "replaced = False\n"
            "def replace(source, destination, *args, **kwargs):\n"
            "    global replaced\n"
            "    result = original_replace(source, destination, *args, **kwargs)\n"
            "    replaced = str(destination).endswith('view.html')\n"
            "    return result\n"
            "def fsync(fd):\n"
            "    if replaced and stat.S_ISDIR(os.fstat(fd).st_mode):\n"
            "        raise OSError('injected viewer directory sync failure')\n"
            "    return original_sync(fd)\n"
            "os.replace, os.fsync = replace, fsync\n")
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotEqual(self.output.read_bytes(), before)
        self.assertIn("saved", result.stderr.lower())
        self.assertIn("injected viewer directory sync failure", result.stderr)

    def test_default_does_not_launch_browser_and_open_is_explicit(self):
        trace = self.project / "browser-command.txt"
        stub = self.project / "record-browser.py"
        stub.write_text("import pathlib, sys\npathlib.Path(" + repr(str(trace))
                        + ").write_text(sys.argv[1], encoding='utf-8')\n", encoding="utf-8")
        self.env["BROWSER"] = shlex.quote(sys.executable) + " " + shlex.quote(str(stub)) + " %s"
        result = self.run_ctx("view")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(trace.exists())
        result = self.run_ctx("view", "--open")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.output.as_uri(), trace.read_text(encoding="utf-8"))

    def test_browser_failure_preserves_generated_html(self):
        self.inject_python(
            "import webbrowser\n"
            "def failed_open(*args, **kwargs):\n"
            "    raise OSError('injected browser failure')\n"
            "webbrowser.open = failed_open\n")
        result = self.run_ctx("view", "--open")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.read_view_model()["viewModelVersion"], 1)
        self.assertIn("view.html", result.stdout + result.stderr)
        self.assertIn("injected browser failure", result.stdout + result.stderr)

    def test_browser_false_result_reports_failure_after_generation(self):
        self.inject_python("import webbrowser\nwebbrowser.open = lambda *a, **k: False\n")
        result = self.run_ctx("view", "--open")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.read_view_model()["viewModelVersion"], 1)
        self.assertIn("browser", (result.stdout + result.stderr).lower())
