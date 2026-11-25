"""Exercise the keyboard tunnel's descriptor handoff and session lifetime on local sockets."""
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "macOS native bridge")
class KeyboardPortTests(unittest.TestCase):
    def test_keyboard_port_handoff_and_cleanup(self):
        bridge = ROOT / "Sources/AppleNativeBridge"
        proxy = bridge / "Transport/CoreDeviceProxy"
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "keyboard-port"
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                "-I" + str(bridge / "include"), "-I" + str(proxy), str(proxy / "KeyboardPort.m"),
                str(ROOT / "Tests/NativeTransport/KeyboardPortTests.m"), "-o", str(binary),
            ], check=True, capture_output=True)
            for mode, expected_exit in [
                ("available", 0), ("refuse", 0), ("media-busy", 0),
                ("media-busy-stop-failed", 1), ("media-busy-provider-close-failed", 1),
            ]:
                client, server = socket.socketpair()
                with self.subTest(mode=mode), client, server:
                    with subprocess.Popen([binary, "provider", mode], stdout=server) as provider:
                        server.close()
                        try:
                            subprocess.run([binary, "client", mode], stdin=client, timeout=5, check=True)
                            client.close()
                            self.assertEqual(provider.wait(timeout=5), expected_exit)
                        finally:
                            if provider.poll() is None:
                                provider.kill()
