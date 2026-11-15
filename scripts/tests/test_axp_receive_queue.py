"""Receive budgets are per backlog and per observation, never per connection traffic."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "native Foundation receive queue")
class AXPReceiveQueueTests(unittest.TestCase):
    def test_budgets_and_concurrent_callbacks(self):
        with tempfile.TemporaryDirectory(prefix="iphone-use-ax-queue-") as directory:
            binary = Path(directory) / "receive-queue"
            source = ROOT / "Sources/AppleNativeBridge/AXP"
            subprocess.run([
                "xcrun", "clang", "-O1", "-g", "-fobjc-arc", "-fsanitize=address,undefined",
                "-framework", "Foundation", "-I" + str(source),
                str(source / "AXPReceiveQueue.m"),
                str(ROOT / "Tests/NativeTransport/AXPReceiveQueueTests.m"), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
