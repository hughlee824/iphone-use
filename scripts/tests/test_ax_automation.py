"""Compile the production lockdown/write path against fake system ABI, without a phone."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "Objective-C Foundation")
class AXAutomationRuntimeTests(unittest.TestCase):
    def test_fixed_key_and_pairing_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="iphone-use-ax-automation-") as directory:
            binary = Path(directory) / "automation"
            source = ROOT / "Sources/AppleNativeBridge"
            subprocess.run([
                "xcrun", "clang", "-O1", "-g", "-fobjc-arc", "-fsanitize=address,undefined",
                "-Ddlopen=TestDlopen", "-Ddlsym=TestDlsym", "-framework", "Foundation",
                str(source / "Transport/DeviceLockdown.m"),
                str(source / "AXP/AXAutomation.m"), str(ROOT / "Tests/NativeTransport/AXAutomationTests.m"),
                "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
