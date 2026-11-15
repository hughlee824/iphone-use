"""Exercise the production read-only collector with deterministic native replies."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "native Foundation validation")
class AXPCollectionTests(unittest.TestCase):
    def test_batch_coverage_supplements_and_failure_boundaries(self):
        with tempfile.TemporaryDirectory(prefix="iphone-use-ax-collection-") as directory:
            binary = Path(directory) / "collection"
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                "-I" + str(ROOT / "Sources/AppleNativeBridge/include"),
                "-I" + str(ROOT / "Sources/AppleNativeBridge/AXP"),
                str(ROOT / "Sources/AppleNativeBridge/AXP/AXPCollection.m"),
                str(ROOT / "Tests/NativeTransport/AXPCollectionTests.m"), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
