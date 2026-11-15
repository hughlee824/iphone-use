"""Deterministic native byte-stream/packet regressions; never uses a phone."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/DeviceIP"
@unittest.skipUnless(sys.platform == "darwin", "native macOS socket adapter")
class DeviceIPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="iphone-use-device-ip-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.binary = Path(cls.temporary.name) / "streams"
        subprocess.run(["xcrun", "clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-I" + str(SOURCE / "include"),
                        str(ROOT / "Tests/NativeTransport/DeviceIPTests.c"), "-o", str(cls.binary)],
                       check=True, capture_output=True, text=True)
        cls.deadlines = Path(cls.temporary.name) / "deadlines"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        "-I" + str(ROOT / "Sources/AppleNativeBridge/include"),
                        str(ROOT / "Tests/NativeTransport/AXPDeadlineTests.m"),
                        str(ROOT / "Sources/AppleNativeBridge/Transport/DTXReadOnlyRequest.m"),
                        str(ROOT / "Sources/AppleNativeBridge/AXP/AXPCollection.m"),
                        str(ROOT / "Sources/AppleNativeBridge/AXP/AXPArchive.m"),
                        str(ROOT / "Sources/AppleNativeBridge/AXP/AXPReceiveQueue.m"), "-o", str(cls.deadlines)],
                       check=True, capture_output=True, text=True)
        cls.archive = Path(cls.temporary.name) / "archive"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        "-I" + str(ROOT / "Sources/AppleNativeBridge/include"),
                        "-I" + str(ROOT / "Sources/AppleNativeBridge/AXP"),
                        str(ROOT / "Sources/AppleNativeBridge/AXP/AXPArchive.m"),
                        str(ROOT / "Tests/NativeTransport/AXPArchiveTests.m"), "-o", str(cls.archive)],
                       check=True, capture_output=True, text=True)

    def test_wire_oracle_rejects_missing_pseudoheader_mutation(self):
        # This mutation escaped the old self-generated fixtures. Compilation failure is not a pass.
        directory = Path(self.temporary.name)
        source = (SOURCE / "DeviceIP.c").read_text()
        original = "uint32_t s=(uint32_t)n+6;\n    for(size_t i=0;i<16;i+=2) s+=r16(src+i)+r16(dst+i);"
        self.assertIn(original, source)
        (directory / "mutant.c").write_text(source.replace(original, "uint32_t s=0; (void)src; (void)dst;"))
        fixture = (ROOT / "Tests/NativeTransport/DeviceIPTests.c").read_text()
        (directory / "mutant-test.c").write_text(fixture.replace(
            '#include "../../Sources/DeviceIP/DeviceIP.c"', '#include "mutant.c"'))
        binary = directory / "mutant"
        subprocess.run(["xcrun", "clang", "-std=c11", "-O1", "-I" + str(SOURCE / "include"),
                        "-I" + str(ROOT / "Tests/NativeTransport"), str(directory / "mutant-test.c"),
                        "-o", str(binary)], check=True, capture_output=True, text=True)
        result = subprocess.run([str(binary), "overlap"], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wire_checksum", result.stderr)

    def test_production_ax_call_and_read_deadlines(self):
        for mode in ("recovered", "call-timeout", "read-timeout"):
            with self.subTest(mode=mode):
                result = subprocess.run([str(self.deadlines), mode], capture_output=True, text=True, timeout=8)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_archive_validation_before_system_decoder(self):
        subprocess.run([str(self.archive)], check=True, capture_output=True, text=True, timeout=10)

    def test_streams_large_response_backpressure_half_close_loss_reset_and_cancel(self):
        for mode in ("overlap", "wrap", "reorder", "fragments", "fragment-overlap", "partial-ack",
                     "persist", "reset", "fin", "closed-drain", "window", "fuzz", "invalid", "timeout",
                     "budget", "slow-rtt", "bulk", "bulk-loss", "multi-flow", "cancel", "fragment-pool", "denial-budget", "idle-window",
                     "state-sequences", "syn-window", "deadline-3-1", "deadline-3-2",
                     "deadline-4-2", "deadline-8-3", "deadline-16-4", "deadline-16-5", "session-idle-data", "session-fragment-expiry"):
            with self.subTest(mode=mode):
                result = subprocess.run([str(self.binary), mode], capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
