"""Shell floor gate: the ldx toolkit requires bash 4+ (issue #20 policy).

macOS ships bash 3.2 in /bin/bash, frozen by Apple. Every ldx entry point
must refuse to run under an older bash with an actionable message
('requires bash 4+') instead of crashing on a missing feature, and every
shell script must at least parse under the bash that runs the suite.
"""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tests.test_ldx_ca import make_env, make_fakes

REPO_ROOT = Path(__file__).resolve().parents[1]
SYSTEM_BASH = "/bin/bash"
FLOOR_MARKER = "requires bash 4+"


def _shebang(path):
    try:
        with path.open(encoding="utf-8", errors="replace") as fh:
            first = fh.readline()
    except OSError:
        return ""
    return first if first.startswith("#!") else ""


def shell_scripts():
    """Every file whose shebang names a sh/bash shell (not zsh)."""
    for path in sorted(REPO_ROOT.rglob("*")):
        parts = path.relative_to(REPO_ROOT).parts
        if not path.is_file() or ".git" in parts or "__pycache__" in parts:
            continue
        shebang = _shebang(path)
        if shebang and "zsh" not in shebang and re.search(r"\bsh\b|/sh$|\bbash\b", shebang):
            yield path


def system_bash_major():
    result = subprocess.run(
        [SYSTEM_BASH, "-c", "echo ${BASH_VERSINFO[0]}"],
        capture_output=True, text=True,
    )
    return int(result.stdout.strip() or 0)


def hermetic_env(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    bin_dir, _ = make_fakes(tmp_path)
    (home / "tmp").mkdir()
    env = make_env(home, bin_dir)
    env["LDX_SECRETS_BACKEND"] = "file"
    return env


class ScriptCoverage(unittest.TestCase):
    def test_core_scripts_in_scope(self):
        names = {str(p.relative_to(REPO_ROOT)) for p in shell_scripts()}
        # Core entry points must be in scope; guards against scanner drift.
        for expected in [
            "bin/ldx",
            "bin/lib/common.sh",
            "bin/commands/ldx-ca",
            "bin/commands/ldx-k8s",
        ]:
            self.assertIn(expected, names)


class SyntaxParse(unittest.TestCase):
    def test_all_scripts_parse(self):
        """bash -n on every shell script: syntax errors fail loudly."""
        for path in shell_scripts():
            result = subprocess.run(
                ["bash", "-n", str(path)], capture_output=True, text=True
            )
            self.assertEqual(
                result.returncode, 0,
                msg="bash -n {}: {}".format(path, result.stderr),
            )


class FloorMessage(unittest.TestCase):
    """Under macOS system bash 3.2, entry points must refuse cleanly."""

    def setUp(self):
        if sys.platform != "darwin" or system_bash_major() >= 4:
            self.skipTest("system bash here is 4+; nothing to refuse")

    def _assert_refusal(self, argv, env, label):
        result = subprocess.run(
            [SYSTEM_BASH, *argv], env=env, cwd=REPO_ROOT,
            capture_output=True, text=True, timeout=60,
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, msg="{} ran under bash 3.2".format(label))
        self.assertIn(FLOOR_MARKER, output,
                      msg="{} under /bin/bash: {}".format(label, output[:2000]))
        self.assertNotIn("invalid option", output)
        self.assertNotIn("unbound variable", output)

    def test_dispatcher_and_commands_refuse_system_bash(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = hermetic_env(Path(tmp))
            self._assert_refusal(
                [str(REPO_ROOT / "bin" / "ldx"), "--help"], env, "bin/ldx")
            commands = sorted(
                p for p in (REPO_ROOT / "bin" / "commands").iterdir() if p.is_file()
            )
            self.assertGreater(len(commands), 10)
            for cmd in commands:
                self._assert_refusal([str(cmd), "--help"], env, cmd.name)

    def test_common_lib_refuses_system_bash(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"HOME": tmp, "PATH": "/usr/bin:/bin"}
            result = subprocess.run(
                [SYSTEM_BASH, "-c",
                 'export HOME="{}"; source "{}/bin/lib/common.sh"'.format(tmp, REPO_ROOT)],
                env=env, capture_output=True, text=True, timeout=60,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(FLOOR_MARKER, result.stderr)

    def test_cvescan_refuses_system_bash(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = hermetic_env(Path(tmp))
            self._assert_refusal(
                [str(REPO_ROOT / "cvescan" / "cvescan.sh"), "--help"],
                env, "cvescan.sh")


if __name__ == "__main__":
    unittest.main()
