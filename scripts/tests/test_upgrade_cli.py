"""Run the actual CLI from isolated release layouts. All downloads are local fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

CLI = Path(os.environ.get("IPHONE_USE_TEST_CLI", Path(__file__).resolve().parents[2] / ".build/debug/iphone-use"))


class UpgradeCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="upgrade test ")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.link = self.home / ".local/bin/iphone-use"
        self.link.parent.mkdir(parents=True)
        self.commands = self.home / "commands"
        self.commands.mkdir()
        self.log = self.home / "installer-args"
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.commands}:/usr/bin:/bin")
        # A failed download can still leave a partial script. It must never run.
        curl = self.commands / "curl"
        curl.write_text('''#!/bin/sh
set -eu
while [ "$1" != --output ]; do shift; done
[ "$3" = 'https://iphone-use.com/install.sh' ]
cat > "$2" <<'SCRIPT'
[ "$(command -v iphone-use)" = "$HOME/.local/bin/iphone-use" ] || exit 2
printf '%s\\n' "$@" > "$HOME/installer-args"
exit "${INSTALLER_STATUS:-0}"
SCRIPT
exit "${CURL_STATUS:-0}"
''')
        curl.chmod(0o755)

    def install(self, relative):
        binary = self.home / relative
        binary.parent.mkdir(parents=True)
        shutil.copy2(CLI, binary)
        self.link.symlink_to(binary)
        return binary

    def upgrade(self, binary=None, **settings):
        return subprocess.run([binary or self.link, "upgrade"], env={**self.env, **settings},
                              capture_output=True, text=True, timeout=10)

    def test_website_install_checks_download_and_propagates_installer_failure(self):
        binary = self.install(".local/share/iphone-use/releases/1.0.0/bin/iphone-use")
        self.assertNotEqual(self.upgrade().returncode, 0)
        (binary.parents[1] / ".curl-installed").touch()
        self.assertNotEqual(self.upgrade(CURL_STATUS="1").returncode, 0)
        self.assertFalse(self.log.exists())
        self.assertNotEqual(self.upgrade(INSTALLER_STATUS="1").returncode, 0)
        result = self.upgrade()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text(), "--upgrade\n")
        self.link.unlink()
        self.log.unlink()
        self.assertNotEqual(self.upgrade(binary).returncode, 0)
        self.assertFalse(self.log.exists())

    def test_homebrew_guidance_and_manual_copy(self):
        self.install("custom prefix/Cellar/iphone-use/1.0.0/libexec/bin/iphone-use")
        result = self.upgrade()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("brew upgrade iphone-use", result.stdout)
        self.link.unlink()
        self.install("manual/bin/iphone-use")
        result = self.upgrade()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("original installation method", result.stderr)
        self.assertFalse(self.log.exists())
