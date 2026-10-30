"""Exercise the real Zig Run cache across changing CI environments (no SDK needed)."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class EmccCacheTest(unittest.TestCase):
    def test_job_identity_is_ignored_but_toolchain_and_inputs_invalidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(Path(__file__).resolve().parents[1] / "backend.hook.zig", root / "hook.zig")
            (root / "build.zig").write_text('''
const std = @import("std");
const hook = @import("hook.zig");
pub fn build(b: *std.Build) void {
    const run = b.addSystemCommand(&.{b.option([]const u8, "python", "Python") .?});
    run.addFileArg(b.path("link.py"));
    hook.pinEmConfig(run, b.option([]const u8, "config", "SDK config").?);
    run.addFileArg(b.path("input.txt"));
    _ = run.addOutputFileArg("game.html");
    b.default_step.dependOn(&run.step);
}
''')
            (root / "link.py").write_text('''
import os, pathlib, sys
assert "CI_JOB_TOKEN" not in os.environ
with open("executions.txt", "a") as f: f.write("link\\n")
pathlib.Path(sys.argv[2]).write_text(pathlib.Path(sys.argv[1]).read_text() + os.environ["EM_CONFIG"])
''')
            (root / "input.txt").write_text("original archive")
            env = dict(os.environ, CI_JOB_ID="1", CI_PIPELINE_ID="10", CI_JOB_TOKEN="fake-token")

            def build(expected, config="sdk-one"):
                result = subprocess.run(
                    [os.environ.get("ZIG", "zig"), "build", "-j2", "--summary", "all",
                     f"-Dpython={sys.executable}", f"-Dconfig={config}"],
                    cwd=root, env=env, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len((root / "executions.txt").read_text().splitlines()), expected,
                                 result.stdout + result.stderr)

            build(1)
            env.update(CI_JOB_ID="2", CI_PIPELINE_ID="20", CI_JOB_TOKEN="different-token",
                       GITHUB_RUN_ID="different-run", EM_CONFIG="ignored-sdk")
            build(1)  # Separate build process and job identity: must hit cache.
            env["EMCC_CFLAGS"] = "-DCHANGED=1"
            build(2)
            build(3, "sdk-two")
            (root / "input.txt").write_text("changed archive")
            build(4, "sdk-two")


if __name__ == "__main__":
    unittest.main()
