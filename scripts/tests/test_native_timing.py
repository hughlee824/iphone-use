"""Opt-in native stage diagnostics must leave stdout and default stderr untouched."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "native Foundation diagnostics")
class NativeTimingTests(unittest.TestCase):
    def test_opt_in_monotonic_metadata_only(self):
        with tempfile.TemporaryDirectory(prefix="iphone-use-native-timing-") as directory:
            binary = Path(directory) / "timing"
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                "-I" + str(ROOT / "Sources/AppleNativeBridge/Transport"),
                str(ROOT / "Tests/NativeTransport/NativeTimingTests.m"), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            for flag in (None, "0", "true", "1"):
                env = dict(os.environ)
                env.pop("IPHONE_USE_NATIVE_TIMINGS", None)
                if flag is not None:
                    env["IPHONE_USE_NATIVE_TIMINGS"] = flag
                result = subprocess.run([str(binary)], env=env, check=True,
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.stdout, "")
                if flag != "1":
                    self.assertEqual(result.stderr, "")
                    continue
                self.assertLess(len(result.stderr), 2100)
                lines = result.stderr.splitlines()
                self.assertEqual(len(lines), 1)
                prefix = "NATIVE_STAGE_TIMING "
                self.assertTrue(lines[0].startswith(prefix))
                record = json.loads(lines[0][len(prefix):])
                self.assertEqual(set(record), {"version", "stage", "startedUptime", "finishedUptime", "elapsedMs"})
                self.assertEqual(record["version"], 1)
                self.assertEqual(record["stage"], "test.completed")
                self.assertGreaterEqual(record["elapsedMs"], 25)
                self.assertAlmostEqual(record["elapsedMs"],
                                       (record["finishedUptime"] - record["startedUptime"]) * 1000, places=5)


if __name__ == "__main__":
    unittest.main()
