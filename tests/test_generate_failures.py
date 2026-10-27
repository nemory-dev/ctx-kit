"""Real-CLI regressions for failures while collecting and publishing context."""

import json
import os
from pathlib import Path
import resource
import shlex
import shutil
import signal
import stat
import subprocess
import tempfile
import textwrap
import unittest


REPO = Path(__file__).resolve().parents[1]


def limit_output_size():
    # A regressed self-collection loop must not grow a fixture without bound.
    resource.setrlimit(resource.RLIMIT_FSIZE, (1024 * 1024, 1024 * 1024))


class GenerateFailureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctx-kit-generate-failure-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve()
        self.script = self.project / "ctx.sh"
        shutil.copy2(REPO / "ctx.sh", self.script)
        self.inputs = self.project / "inputs"
        self.inputs.mkdir()
        (self.inputs / "01-first.txt").write_bytes(b"First complete input\n")
        self.failing_input = self.inputs / "02-second.txt"
        self.failing_input.write_bytes(b"Second input, including binary: \x00\xff\n" * 4096)
        self.output = self.project / "generated/context.md"
        self.output.parent.mkdir()
        self.original = b"Previous complete bundle\n\x00\xff\n"
        self.output.write_bytes(self.original)
        self.output.chmod(0o640)
        self.original_mode = stat.S_IMODE(self.output.stat().st_mode)
        (self.project / "ctx.config.json").write_text(
            json.dumps({
                "source": "context/AGENT_RULES.md",
                "generate": {"project": {
                    "collect": ["inputs/*.txt"],
                    "output": "generated/context.md",
                }},
            }),
            encoding="utf-8",
        )
        self.env = os.environ.copy()
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.install_fault_hooks()

    def install_fault_hooks(self):
        # Inject failures at filesystem boundaries, including fdopen streams,
        # so permissions or the test runner's effective user do not matter.
        hooks = self.project / "python-hooks"
        hooks.mkdir()
        (hooks / "sitecustomize.py").write_text(textwrap.dedent('''\
            import builtins
            import io
            import os

            _fault = os.environ.get("CTX_TEST_GENERATE_FAULT")
            _input = os.environ.get("CTX_TEST_GENERATE_INPUT")
            _output = os.environ.get("CTX_TEST_GENERATE_OUTPUT")
            _directory = os.path.dirname(_output) if _output else None
            _open = builtins.open
            _io_open = io.open
            _fdopen = os.fdopen
            _os_open = os.open
            _write = os.write
            _fsync = os.fsync
            _replace = os.replace
            _staged_inodes = set()

            def normalized(path):
                if isinstance(path, int):
                    return None
                try:
                    return os.path.abspath(os.fsdecode(path))
                except TypeError:
                    return None

            def is_staged(path):
                path = normalized(path)
                return (path is not None and os.path.dirname(path) == _directory
                        and os.path.basename(path).startswith(".ctx-write-"))

            def inode(fd):
                info = os.fstat(fd)
                return info.st_dev, info.st_ino

            def staged_fd(fd):
                return inode(fd) in _staged_inodes

            def failure(stage):
                raise OSError("injected generate " + stage + " failure")

            class FaultStream:
                def __init__(self, stream, reading=False, writing=False):
                    self.stream = stream
                    self.reading = reading
                    self.writing = writing
                    self.reads = 0
                    self.flush_failed = False

                def __getattr__(self, name):
                    return getattr(self.stream, name)

                def __enter__(self):
                    self.stream.__enter__()
                    return self

                def __exit__(self, *args):
                    try:
                        if self.writing and _fault == "flush":
                            self.flush()
                    finally:
                        self.stream.__exit__(*args)

                def read(self, size=-1):
                    if self.reading and _fault == "read-mid":
                        if self.reads:
                            failure("read-mid")
                        self.reads += 1
                        chunk = self.stream.read(7)
                        if size < 0:
                            failure("read-mid")
                        return chunk
                    return self.stream.read(size)

                def readinto(self, buffer):
                    if self.reading and _fault == "read-mid":
                        chunk = self.read(len(buffer))
                        buffer[:len(chunk)] = chunk
                        return len(chunk)
                    return self.stream.readinto(buffer)

                def write(self, value):
                    if self.writing and _fault == "write":
                        self.stream.write(value[:7])
                        failure("write")
                    return self.stream.write(value)

                def flush(self):
                    if self.writing and _fault == "flush" and not self.flush_failed:
                        self.flush_failed = True
                        failure("flush")
                    return self.stream.flush()

            def opening(opener, path, *args, **kwargs):
                target = normalized(path)
                reading = target == _input
                if reading and _fault == "read-open":
                    failure("read-open")
                stream = opener(path, *args, **kwargs)
                if isinstance(stream, FaultStream):
                    return stream
                writing = is_staged(path) or (isinstance(path, int) and staged_fd(path))
                if writing:
                    _staged_inodes.add(inode(stream.fileno()))
                if reading or writing:
                    return FaultStream(stream, reading, writing)
                return stream

            def fail_open(path, *args, **kwargs):
                return opening(_open, path, *args, **kwargs)

            def fail_io_open(path, *args, **kwargs):
                return opening(_io_open, path, *args, **kwargs)

            def fail_fdopen(fd, *args, **kwargs):
                return opening(_fdopen, fd, *args, **kwargs)

            def fail_os_open(path, *args, **kwargs):
                fd = _os_open(path, *args, **kwargs)
                if is_staged(path):
                    _staged_inodes.add(inode(fd))
                return fd

            def fail_write(fd, value):
                if _fault == "write" and staged_fd(fd):
                    _write(fd, value[:7])
                    failure("write")
                return _write(fd, value)

            def fail_fsync(fd):
                if _fault == "fsync" and staged_fd(fd):
                    failure("fsync")
                result = _fsync(fd)
                if staged_fd(fd):
                    if _fault == "change-output":
                        with _open(_output, "wb") as changed:
                            changed.write(os.environ["CTX_TEST_GENERATE_CHANGED"].encode("utf-8"))
                    elif _fault == "symlink-output":
                        os.unlink(_output)
                        os.symlink(os.environ["CTX_TEST_GENERATE_TARGET"], _output)
                return result

            def fail_replace(source, destination, *args, **kwargs):
                if _fault == "replace" and normalized(destination) == _output:
                    failure("replace")
                return _replace(source, destination, *args, **kwargs)

            builtins.open = fail_open
            io.open = fail_io_open
            os.fdopen = fail_fdopen
            os.open = fail_os_open
            os.write = fail_write
            os.fsync = fail_fsync
            os.replace = fail_replace
            '''), encoding="utf-8")
        self.env["PYTHONPATH"] = str(hooks) + os.pathsep + self.env.get("PYTHONPATH", "")
        self.env["CTX_TEST_GENERATE_INPUT"] = str(self.failing_input)
        self.env["CTX_TEST_GENERATE_OUTPUT"] = str(self.output)

        # The previous implementation reads with cat, so the same read fault
        # also reaches that CLI rather than silently testing only Python code.
        binary = self.project / "test-bin"
        binary.mkdir()
        cat = binary / "cat"
        cat.write_text(
            "#!/bin/sh\n"
            'for argument do\n'
            '  if [ "$argument" = "$CTX_TEST_GENERATE_INPUT" ]; then\n'
            '    case "$CTX_TEST_GENERATE_FAULT" in\n'
            '      read-mid) ' + shlex.quote(shutil.which("head")) + ' -c 7 "$argument" ;;\n'
            '      read-open) ;;\n'
            '      *) exec ' + shlex.quote(shutil.which("cat")) + ' "$@" ;;\n'
            '    esac\n'
            '    printf "injected generate %s failure\\n" "$CTX_TEST_GENERATE_FAULT" >&2\n'
            '    exit 71\n'
            '  fi\n'
            'done\n'
            'exec ' + shlex.quote(shutil.which("cat")) + ' "$@"\n',
            encoding="utf-8",
        )
        cat.chmod(0o755)
        self.env["PATH"] = str(binary) + os.pathsep + self.env.get("PATH", "")

    def run_failure(self, stage, injected=True):
        self.env["CTX_TEST_GENERATE_FAULT"] = stage
        command = ["bash", str(self.script), "generate", "project"]
        process = subprocess.Popen(
            command, cwd=self.project, env=self.env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True,
            preexec_fn=limit_output_size,
        )
        try:
            stdout, stderr = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            self.fail("generate timed out: " + stdout + stderr)
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(result.stderr.strip())
        if injected:
            self.assertIn("injected generate " + stage + " failure", result.stderr)
        self.assertNotIn("file(s) collected", result.stdout)
        self.assertNotIn("Open and paste", result.stdout)
        self.assertEqual(list(self.project.rglob(".ctx-write-*")), [])
        return result

    def assert_original_preserved(self):
        self.assertEqual(self.output.read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), self.original_mode)

    def test_second_input_open_failure_preserves_existing_output(self):
        self.run_failure("read-open")
        self.assert_original_preserved()

    def test_second_input_mid_read_failure_preserves_existing_output(self):
        self.run_failure("read-mid")
        self.assert_original_preserved()

    def test_second_input_read_failure_does_not_create_new_output(self):
        self.output.unlink()
        self.run_failure("read-open")
        self.assertFalse(self.output.exists())

    def test_temporary_write_failure_preserves_existing_output(self):
        self.run_failure("write")
        self.assert_original_preserved()

    def test_temporary_flush_failure_preserves_existing_output(self):
        self.run_failure("flush")
        self.assert_original_preserved()

    def test_temporary_fsync_failure_preserves_existing_output(self):
        self.run_failure("fsync")
        self.assert_original_preserved()

    def test_final_replacement_failure_preserves_existing_output(self):
        self.run_failure("replace")
        self.assert_original_preserved()

    def test_external_output_edit_during_generation_is_preserved(self):
        changed = "A complete newer bundle saved by another writer\n"
        self.env["CTX_TEST_GENERATE_CHANGED"] = changed
        self.run_failure("change-output", injected=False)
        self.assertEqual(self.output.read_bytes(), changed.encode("utf-8"))
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), self.original_mode)

    def test_external_output_symlink_during_generation_is_preserved(self):
        target = self.project / "external-target.txt"
        content = b"External target must remain unchanged\n\x00\xff\n"
        target.write_bytes(content)
        self.env["CTX_TEST_GENERATE_TARGET"] = str(target)
        self.run_failure("symlink-output", injected=False)
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(os.readlink(self.output), str(target))
        self.assertEqual(target.read_bytes(), content)


if __name__ == "__main__":
    unittest.main()
