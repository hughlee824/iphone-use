"""Native helper failure envelopes preserve recovery categories through cleanup; no phone access."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "native Foundation worker protocol")
class ObservationFailureTests(unittest.TestCase):
    @staticmethod
    def compile_peer(binary, request_source):
        source = ROOT / "Sources/AppleNativeBridge"
        subprocess.run([
            "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
            "-I" + str(source / "include"), "-I" + str(source / "Observation"),
            "-I" + str(source / "Transport"), str(request_source),
            str(source / "Observation/ObservationWorker.m"),
            str(source / "AXP/AXPCollection.m"), str(source / "AXP/AXPArchive.m"),
            str(source / "AXP/AXPReceiveQueue.m"),
            str(ROOT / "Tests/NativeTransport/ObservationFailureTests.m"), "-o", str(binary),
        ], check=True, capture_output=True, text=True)

    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="iphone-use-observation-failure-")
        cls.addClassCleanup(temporary.cleanup)
        cls.binary = Path(temporary.name) / "worker"
        cls.compile_peer(cls.binary, ROOT / "Sources/AppleNativeBridge/Transport/DTXReadOnlyRequest.m")

    def test_screenshot_cutoff_is_exclusive_and_scoped_to_one_capture(self):
        generation = "00000000-0000-0000-0000-000000000001"
        capture = {"op": "capture", "generation": generation, "id": generation}
        commands = [dict(capture, screenshotStartDeadline=1.5), capture, {"op": "close", "generation": generation}]
        result = subprocess.run([self.binary, "screenshot_cutoff"], check=True, text=True, capture_output=True,
                                input="".join(json.dumps(c) + "\n" for c in commands), timeout=5)
        values = [e["value"] for e in map(json.loads, result.stdout.splitlines()) if e["event"] == "result"]
        self.assertEqual(values, [{"before": True, "at": False, "after": False},
                                  {"before": True, "at": True, "after": True}])

    def test_dtx_unexpected_return_cannot_borrow_legacy_connection_failure(self):
        with tempfile.TemporaryDirectory(prefix="iphone-use-dtx-return-") as directory:
            root = Path(directory)
            stub = root / "returning-request.m"
            stub.write_text('''#import "DTXReadOnlyRequest.h"
@implementation ASDTXReadConnectionState
- (void)markDisconnected {}
- (BOOL)isDisconnected { return YES; }
@end
id ASDTXReadOnlyRequest(id channel, NSString *selector, NSTimeInterval timeout,
                       ASDTXReadConnectionState *state, NSString *context) { return nil; }
id ASDTXReadOnlyRequestWithObjects(id channel, NSString *selector, NSArray *objects, NSTimeInterval timeout,
                                  ASDTXReadConnectionState *state, NSString *context) { return nil; }
''')
            binary = root / "worker"
            self.compile_peer(binary, stub)
            command = json.dumps({
                "op": "capture", "generation": "00000000-0000-0000-0000-000000000001",
                "id": "00000000-0000-0000-0000-000000000002",
            }) + "\n"
            for mode in ("recover_dtx", "recover_dtx_late", "recover_dtx_deadline"):
                with self.subTest(mode=mode):
                    Path(str(binary) + ".first").unlink(missing_ok=True)
                    result = subprocess.run([str(binary), mode], input=command,
                                            capture_output=True, text=True, timeout=5)
                    events = [json.loads(line) for line in result.stdout.splitlines()]
                    self.assertEqual(result.returncode, 1, result.stderr)
                    closed = [event for event in events if event["event"] == "closed"]
                    self.assertEqual(len(closed), 1)
                    self.assertEqual(closed[0]["errorKind"], "failure")
                    self.assertEqual(closed[0]["error"], "DTX interruption unexpectedly returned")
                    self.assertFalse(any(event.get("value", {}).get("recovered") for event in events))

    def test_failure_classification_survives_native_cleanup_and_json(self):
        cases = {
            "connection": "connection", "semantic": "semantic", "misleading": "failure",
            "budget": "failure", "no_reason": "failure", "native_connection_lost": "connection",
            "native_connection_closed": "connection", "native_connect_failed": "connection",
            "native_handshake_timeout": "connection", "native_invalid_reply": "failure",
            "native_protocol_unsupported": "failure", "native_device_mismatch": "failure",
        }
        for mode, kind in cases.items():
            with self.subTest(mode=mode):
                result = subprocess.run([str(self.binary), mode], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1, result.stderr)
                reply = json.loads(result.stdout)
                self.assertEqual(reply["event"], "closed")
                self.assertEqual(reply["errorKind"], kind)
                self.assertIsInstance(reply["error"], str)
                self.assertTrue(reply["cleanup"]["connectionClosed"])
                self.assertTrue(reply["cleanup"]["tunnelClosed"])

    def test_normal_close_has_no_failure_kind(self):
        result = subprocess.run([str(self.binary), "normal"], check=True, capture_output=True, text=True, timeout=5)
        reply = json.loads(result.stdout)
        self.assertIsNone(reply["error"])
        self.assertIsNone(reply["errorKind"])


if __name__ == "__main__":
    unittest.main()
