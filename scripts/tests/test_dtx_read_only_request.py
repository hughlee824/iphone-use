"""Read-only DTX failures use corroborated connection state; real local sockets, no phone."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "system DTX framework")
class DTXReadOnlyRequestTests(unittest.TestCase):
    def test_classification_and_real_transport_interruptions(self):
        with tempfile.TemporaryDirectory(prefix="iphone-use-dtx-read-") as directory:
            binary = Path(directory) / "dtx-read"
            source = ROOT / "Sources/AppleNativeBridge/Transport"
            subprocess.run([
                "xcrun", "clang", "-O1", "-g", "-fobjc-arc", "-fsanitize=address,undefined",
                "-framework", "Foundation", "-I" + str(source),
                str(source / "DTXReadOnlyRequest.m"),
                str(ROOT / "Tests/NativeTransport/DTXReadOnlyRequestTests.m"), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
