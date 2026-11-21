"""Production AX display validation and bounded diagnostics; no device connection."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "native Foundation validation")
class AXPDisplayTests(unittest.TestCase):
    def test_rejection_fields_and_bounded_metadata(self):
        with tempfile.TemporaryDirectory(prefix="iphone-use-ax-display-") as directory:
            binary = Path(directory) / "display"
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                "-I" + str(ROOT / "Sources/AppleNativeBridge/include"),
                "-I" + str(ROOT / "Sources/AppleNativeBridge/AXP"),
                str(ROOT / "Sources/AppleNativeBridge/AXP/AXPDisplay.m"),
                str(ROOT / "Tests/NativeTransport/AXPDisplayTests.m"), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
