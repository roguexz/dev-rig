"""Regression tests for the ldx ca command (validation, install, failure paths).

These run the real bash script with HOME redirected to a temp directory and
fake kubectl/mkcert binaries on PATH, so they are hermetic: no cluster access,
no writes to the real ~/.cache/local-dev.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CA_CMD = REPO_ROOT / "bin" / "commands" / "ldx-ca"


def run_ca(args, env, cwd=None, bash="bash"):
    return subprocess.run(
        [bash, str(CA_CMD), *args],
        env=env,
        cwd=cwd or REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=60,
    )


def write_executable(path, content):
    path.write_text(content)
    path.chmod(0o755)


def make_fakes(tmp_dir):
    """Fake kubectl/mkcert on PATH. kubectl logs every invocation to a file."""
    bin_dir = tmp_dir / "fake-bin"
    bin_dir.mkdir()
    log_file = tmp_dir / "kubectl-calls.log"
    write_executable(
        bin_dir / "kubectl",
        f'#!/bin/sh\necho "$@" >> "{log_file}"\nexit 0\n',
    )
    write_executable(
        bin_dir / "mkcert",
        '#!/bin/sh\ncase "$1" in\n  -CAROOT) echo "' + str(tmp_dir / "mkcert-root") + '" ;;\n  *) exit 0 ;;\nesac\n',
    )
    return bin_dir, log_file


def make_env(home, bin_dir):
    env = {
        "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "TMPDIR": str(home / "tmp"),
    }
    return env


class CaInstallBadFile(unittest.TestCase):
    def test_bad_file_fails_and_installs_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            home.mkdir()
            bin_dir, _ = make_fakes(Path(tmp))
            (home / "tmp").mkdir()

            dir_with_bad = Path(tmp) / "ca-src"
            dir_with_bad.mkdir()
            (dir_with_bad / "bad.pem").write_text("this is not a pem certificate\n")

            env = make_env(home, bin_dir)
            result = run_ca(["install", "--dir", str(dir_with_bad)], env)

            self.assertNotEqual(result.returncode, 0)
            output = result.stdout + result.stderr
            self.assertIn("No valid CA", output)
            self.assertIn("bad.pem", output)

            ca_dir = home / ".cache" / "local-dev" / "ca"
            self.assertFalse(ca_dir.exists() and list(ca_dir.glob("*.pem")))


class CaInstallValidPem(unittest.TestCase):
    def test_valid_pem_installs_and_refreshes_configmap(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home = tmp_path / "home"
            home.mkdir()
            bin_dir, log_file = make_fakes(tmp_path)
            (home / "tmp").mkdir()

            dir_with_ca = tmp_path / "ca-src"
            dir_with_ca.mkdir()
            cert = dir_with_ca / "test-ca.pem"
            subprocess.run(
                [
                    "openssl", "req", "-x509", "-newkey", "rsa:2048",
                    "-keyout", str(dir_with_ca / "key.pem"),
                    "-out", str(cert),
                    "-days", "3650", "-nodes",
                    "-subj", "/CN=Test CA", "-batch",
                ],
                capture_output=True,
                check=True,
            )

            env = make_env(home, bin_dir)
            result = run_ca(["install", "--dir", str(dir_with_ca)], env)

            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            output = result.stdout + result.stderr
            self.assertIn("Installed 1 CA certificate", output)

            # Cache file name derives from the cert (subject slug + short
            # fingerprint), not from the source file name.
            ca_dir = home / ".cache" / "local-dev" / "ca"
            installed = list(ca_dir.glob("*.pem"))
            self.assertEqual(len(installed), 1)
            self.assertTrue(installed[0].name.startswith("test-ca-"))
            self.assertEqual(installed[0].read_text().count("BEGIN CERTIFICATE"), 1)

            # The extra-cas ConfigMap was re-created via the fake kubectl.
            calls = log_file.read_text()
            self.assertIn("configmap extra-cas", calls)


class CaUsage(unittest.TestCase):
    def test_no_subcommand_shows_usage(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            home.mkdir()
            bin_dir, _ = make_fakes(Path(tmp))
            (home / "tmp").mkdir()

            env = make_env(home, bin_dir)
            result = run_ca([], env)

            self.assertEqual(result.returncode, 1)
            self.assertIn("Usage:", result.stdout)


class CaInstallSplitBundle(unittest.TestCase):
    def make_bundle(self, dir_path):
        """Write a 3-cert bundle (and its individual certs in a scratch dir)
        and return the bundle path."""
        scratch = dir_path / "_scratch"
        scratch.mkdir()
        certs = []
        for i in range(1, 4):
            cert = scratch / f"cert{i}.pem"
            subprocess.run(
                [
                    "openssl", "req", "-x509", "-newkey", "rsa:2048",
                    "-keyout", str(scratch / f"key{i}.pem"),
                    "-out", str(cert),
                    "-days", "3650", "-nodes",
                    "-subj", f"/CN=Test CA {i}", "-batch",
                ],
                capture_output=True,
                check=True,
            )
            certs.append(cert)
        bundle = dir_path / "bundle.pem"
        with bundle.open("w") as out:
            for cert in certs:
                out.write(cert.read_text())
        return bundle

    def test_split_flag_imports_each_cert_in_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home = tmp_path / "home"
            home.mkdir()
            bin_dir, _ = make_fakes(tmp_path)
            (home / "tmp").mkdir()

            dir_with_ca = tmp_path / "ca-src"
            dir_with_ca.mkdir()
            bundle = self.make_bundle(dir_with_ca)
            shutil.rmtree(dir_with_ca / "_scratch")

            env = make_env(home, bin_dir)
            result = run_ca(
                ["install", "--dir", str(dir_with_ca), "--split"], env
            )

            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            output = result.stdout + result.stderr
            self.assertIn("Installed 3 CA certificate", output)

            ca_dir = home / ".cache" / "local-dev" / "ca"
            installed = list(ca_dir.glob("*.pem"))
            self.assertEqual(len(installed), 3)
            fps = set()
            for cert in installed:
                content = cert.read_text()
                self.assertEqual(content.count("BEGIN CERTIFICATE"), 1)
                out = subprocess.run(
                    ["openssl", "x509", "-in", str(cert), "-noout",
                     "-fingerprint", "-sha256"],
                    capture_output=True, text=True,
                )
                fps.add(out.stdout.strip())
            # Each installed file is a distinct certificate.
            self.assertEqual(len(fps), 3)

    def test_bundle_without_split_warns_and_uses_first_cert(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home = tmp_path / "home"
            home.mkdir()
            bin_dir, _ = make_fakes(tmp_path)
            (home / "tmp").mkdir()

            dir_with_ca = tmp_path / "ca-src"
            dir_with_ca.mkdir()
            self.make_bundle(dir_with_ca)
            shutil.rmtree(dir_with_ca / "_scratch")

            env = make_env(home, bin_dir)
            result = run_ca(["install", "--dir", str(dir_with_ca)], env)

            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            output = result.stdout + result.stderr
            self.assertIn("--split", output)
            self.assertIn("Installed 1 CA certificate", output)

            ca_dir = home / ".cache" / "local-dev" / "ca"
            self.assertEqual(len(list(ca_dir.glob("*.pem"))), 1)


class CaInstallFingerprintDedup(unittest.TestCase):
    def make_cert(self, dir_path, cn):
        cert = dir_path / "cert.pem"
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", str(dir_path / "key.pem"),
                "-out", str(cert),
                "-days", "3650", "-nodes",
                "-subj", f"/CN={cn}", "-batch",
            ],
            capture_output=True,
            check=True,
        )
        return cert

    def test_duplicate_cert_installed_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home = tmp_path / "home"
            home.mkdir()
            bin_dir, _ = make_fakes(tmp_path)
            (home / "tmp").mkdir()

            dir_with_ca = tmp_path / "ca-src"
            dir_with_ca.mkdir()
            cert = self.make_cert(dir_with_ca, "Dedup CA")
            # openssl req writes the private key next to the cert; drop it,
            # leaving only the certificate files in the directory.
            (dir_with_ca / "key.pem").unlink()
            # Same cert under a second file name in the same directory.
            (dir_with_ca / "other-name.pem").write_text(cert.read_text())

            env = make_env(home, bin_dir)
            result = run_ca(["install", "--dir", str(dir_with_ca)], env)

            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            output = result.stdout + result.stderr
            self.assertIn("Installed 1 CA certificate", output)
            self.assertIn("already installed", output)

            ca_dir = home / ".cache" / "local-dev" / "ca"
            self.assertEqual(len(list(ca_dir.glob("*.pem"))), 1)

    def test_reinstall_is_a_noop(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home = tmp_path / "home"
            home.mkdir()
            bin_dir, _ = make_fakes(tmp_path)
            (home / "tmp").mkdir()

            dir_with_ca = tmp_path / "ca-src"
            dir_with_ca.mkdir()
            self.make_cert(dir_with_ca, "Re-install CA")
            # Drop the private key openssl req writes next to the cert.
            (dir_with_ca / "key.pem").unlink()

            env = make_env(home, bin_dir)
            first = run_ca(["install", "--dir", str(dir_with_ca)], env)
            self.assertEqual(first.returncode, 0, msg=first.stdout + first.stderr)

            second = run_ca(["install", "--dir", str(dir_with_ca)], env)
            self.assertEqual(second.returncode, 0, msg=second.stdout + second.stderr)
            output = second.stdout + second.stderr
            self.assertIn("already installed", output)

            ca_dir = home / ".cache" / "local-dev" / "ca"
            self.assertEqual(len(list(ca_dir.glob("*.pem"))), 1)


class CaRequiresBash4(unittest.TestCase):
    """Issue #20 policy: bash 4+ required. Under macOS system bash 3.2 the
    command must refuse with the install hint, not crash on 'declare -A'."""

    def system_bash_major(self):
        result = subprocess.run(
            ["/bin/bash", "-c", "echo ${BASH_VERSINFO[0]}"],
            capture_output=True, text=True,
        )
        return int(result.stdout.strip() or 0)

    def test_refuses_system_bash_with_actionable_message(self):
        if sys.platform != "darwin" or self.system_bash_major() >= 4:
            self.skipTest("system bash here is 4+; nothing to refuse")

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home = tmp_path / "home"
            home.mkdir()
            bin_dir, _ = make_fakes(tmp_path)
            (home / "tmp").mkdir()

            dir_with_ca = tmp_path / "ca-src"
            dir_with_ca.mkdir()
            (dir_with_ca / "test-ca.pem").write_text("irrelevant; refusal happens first\n")

            env = make_env(home, bin_dir)
            result = run_ca(["install", "--dir", str(dir_with_ca)], env, bash="/bin/bash")

            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires bash 4+", output)
            self.assertNotIn("invalid option", output)


if __name__ == "__main__":
    unittest.main()
