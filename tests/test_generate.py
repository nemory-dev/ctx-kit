"""Real-CLI regressions for safe generation and byte-preserving collection."""

import json
import os
from pathlib import Path
import resource
import shutil
import signal
import stat
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
FILE_SIZE_LIMIT = 1024 * 1024


def limit_child_file_size():
    # The previous self-collection bug could grow the output without bound.
    resource.setrlimit(resource.RLIMIT_FSIZE, (FILE_SIZE_LIMIT, FILE_SIZE_LIMIT))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class GenerateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-generate-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        self.install()

    def install(self, scripts=False, name="project"):
        self.project = self.base / name
        self.script = self.project / ("scripts/ctx.sh" if scripts else "ctx.sh")
        self.script.parent.mkdir(parents=True)
        shutil.copy2(REPO / "ctx.sh", self.script)

    def configure(self, collect, output="generated/context.md"):
        config = {
            "source": "sample-context/AGENT_RULES.md",
            "generate": {"project": {"collect": collect, "output": output}},
        }
        (self.project / "ctx.config.json").write_text(
            json.dumps(config, ensure_ascii=False), encoding="utf-8"
        )
        return self.project / output

    def write(self, relative, contents):
        path = self.project / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
        return path

    def run_generate(self):
        process = subprocess.Popen(
            ["bash", str(self.script), "generate", "project"],
            cwd=self.project, env=self.env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace",
            start_new_session=True, preexec_fn=limit_child_file_size,
        )
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            # Killing only Bash leaves a self-reading cat holding pipes open.
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            stdout, stderr = process.communicate()
            self.fail("generate timed out after process-group cleanup:\n" + stdout + stderr)
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_failure(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(result.stderr.strip(), "generate must explain failures on stderr")

    def test_recursive_glob_excludes_existing_output(self):
        source = self.write("docs/spec.md", b"source contract\n")
        output = self.configure(["docs/**/*.md"], "docs/generated/context.md")
        self.write("docs/generated/context.md", b"previous generated context\n")

        self.assert_success(self.run_generate())

        generated = output.read_bytes()
        self.assertIn(b"## [docs/spec.md]\n", generated)
        self.assertIn(b"source contract\n", generated)
        self.assertNotIn(b"## [docs/generated/context.md]", generated)
        self.assertNotIn(b"previous generated context", generated)
        self.assertEqual(source.read_bytes(), b"source contract\n")

    def test_globs_do_not_collect_new_output_or_staging_files(self):
        self.write("docs/spec.md", b"source contract\n")
        (self.project / "generated").mkdir()
        output = self.configure(["docs/*.md", "generated/*", "generated/.*"])

        self.assert_success(self.run_generate())

        generated = output.read_bytes()
        self.assertIn(b"source contract\n", generated)
        self.assertEqual(generated.count(b"\n## ["), 1)
        self.assertEqual(list(output.parent.iterdir()), [output])

    def test_output_only_input_fails_preserving_existing_output(self):
        output = self.configure(["generated/context.md"])
        original = b"keep the previous result\n"
        self.write("generated/context.md", original)

        self.assert_failure(self.run_generate())

        self.assertEqual(output.read_bytes(), original)

    def test_no_regular_input_fails_preserving_output_state(self):
        (self.project / "empty-directory").mkdir()
        for existing in (False, True):
            with self.subTest(existing=existing):
                output = self.configure(["missing/**/*.md", "empty-directory"])
                if existing:
                    self.write("generated/context.md", b"keep previous result\n")

                self.assert_failure(self.run_generate())

                if existing:
                    self.assertEqual(output.read_bytes(), b"keep previous result\n")
                else:
                    self.assertFalse(output.exists())

    def test_output_alias_inputs_are_excluded_and_hardlink_data_is_preserved(self):
        output = self.configure(["inputs/*.md", "generated/context.md"])
        original = b"previous generated context\n"
        self.write("generated/context.md", original)
        self.write("inputs/source.md", b"real input\n")
        symbolic = self.project / "inputs/symbolic.md"
        symbolic.symlink_to(output)
        hardlink = self.project / "inputs/hardlink.md"
        os.link(output, hardlink)

        self.assert_success(self.run_generate())

        generated = output.read_bytes()
        self.assertIn(b"real input\n", generated)
        self.assertEqual(generated.count(b"\n## ["), 1)
        self.assertNotIn(b"previous generated context", generated)
        self.assertEqual(hardlink.read_bytes(), original)
        self.assertTrue(symbolic.is_symlink())

    def test_alias_only_inputs_fail_preserving_output(self):
        output = self.configure(["alias.md"])
        original = b"keep output and alias data\n"
        alias = self.project / "alias.md"
        for kind in ("symbolic", "hardlink"):
            with self.subTest(kind=kind):
                self.write("generated/context.md", original)
                if kind == "symbolic":
                    alias.symlink_to(output)
                else:
                    os.link(output, alias)
                try:
                    self.assert_failure(self.run_generate())

                    self.assertEqual(output.read_bytes(), original)
                    self.assertEqual(alias.read_bytes(), original)
                finally:
                    alias.unlink()

    def test_output_symlinks_are_refused_without_touching_targets(self):
        self.write("input.md", b"new context\n")
        for dangling in (False, True):
            with self.subTest(dangling=dangling):
                output = self.configure(["input.md"], "output-{}.md".format(dangling))
                target = self.project / "target-{}.md".format(dangling)
                if not dangling:
                    target.write_bytes(b"keep target\n")
                output.symlink_to(target)
                link = os.readlink(output)

                self.assert_failure(self.run_generate())

                self.assertTrue(output.is_symlink())
                self.assertEqual(os.readlink(output), link)
                if dangling:
                    self.assertFalse(target.exists())
                else:
                    self.assertEqual(target.read_bytes(), b"keep target\n")

    def test_nonregular_outputs_are_refused_without_replacing_entries(self):
        self.write("input.md", b"new context\n")
        for kind in ("directory", "fifo"):
            with self.subTest(kind=kind):
                output = self.configure(["input.md"], kind)
                if kind == "directory":
                    output.mkdir()
                    (output / "keep.txt").write_bytes(b"keep child\n")
                else:
                    os.mkfifo(output)
                before = output.lstat()

                self.assert_failure(self.run_generate())

                after = output.lstat()
                self.assertEqual((after.st_ino, after.st_mode), (before.st_ino, before.st_mode))
                if kind == "directory":
                    self.assertEqual((output / "keep.txt").read_bytes(), b"keep child\n")

    def test_success_replaces_output_atomically_and_preserves_mode(self):
        self.write("input.md", b"new context\n")
        output = self.configure(["input.md"])
        original = b"old complete context\n"
        self.write("generated/context.md", original)
        output.chmod(0o640)
        with output.open("rb") as previous:
            self.assert_success(self.run_generate())

            self.assertEqual(previous.read(), original)
        self.assertIn(b"new context\n", output.read_bytes())
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o640)

    def test_write_failure_preserves_existing_output_and_removes_staging_files(self):
        self.write("large.bin", b"x" * (FILE_SIZE_LIMIT + 1))
        output = self.configure(["large.bin"])
        original = b"keep complete output after failed write\n"
        self.write("generated/context.md", original)

        self.assert_failure(self.run_generate())

        self.assertEqual(output.read_bytes(), original)
        self.assertEqual(list(output.parent.iterdir()), [output])

    def test_binary_bytes_repeated_patterns_and_quoted_scripts_paths(self):
        for scripts in (False, True):
            with self.subTest(scripts=scripts):
                self.install(scripts=scripts, name="project's 한글 space-{}".format(scripts))
                filename = "input's 한글 folder/raw's data.bin"
                payload = b"\x00\xff\x80\r\nraw bytes\x00"
                self.write(filename, payload)
                output = self.configure(
                    [filename, filename], "generated's 한글 folder/context's raw.md"
                )

                self.assert_success(self.run_generate())

                generated = output.read_bytes()
                self.assertEqual(generated.count(payload), 2)
                self.assertEqual(generated.count(("## [{}]".format(filename)).encode()), 2)


if __name__ == "__main__":
    unittest.main()
