"""Check the discovery capabilities advertised to service peers."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "macOS RemoteXPC framework")
class RSDHandshakeTests(unittest.TestCase):
    def test_discovery_announces_local_receive_capabilities(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "discovery"
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                "-I" + str(ROOT / "Sources/AppleNativeBridge/include"),
                str(ROOT / "Tests/NativeTransport/RSDHandshakeTests.m"), "-o", str(binary),
            ], check=True)
            subprocess.run([binary], check=True)
