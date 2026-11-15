"""Real multi-process host death / helper ownership; only fake preference files, no phone."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
CLI = Path(os.environ.get("IPHONE_USE_TEST_CLI", ROOT / ".build/debug/iphone-use")).resolve()


@unittest.skipUnless(sys.platform == "darwin", "Darwin descriptor inheritance and flock")
class AXAutomationOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="ax-ownership-build-")
        cls.addClassCleanup(cls.build.cleanup)
        folder = Path(cls.build.name)
        modulemap = folder / "module.modulemap"
        modulemap.write_text('module AppleNativeBridge { header "' + str(
            ROOT / "Sources/AppleNativeBridge/include/AppleNativeBridge.h") + '" export * }\n')
        binary_dir = CLI.parent
        objects = []
        for target in ("IPhoneUseCore", "IPhoneUseRunnerSupport", "AppleNativeBridge", "DeviceIP"):
            combined = binary_dir / (target + ".o")
            inputs = [combined] if combined.is_file() else sorted((binary_dir / (target + ".build")).rglob("*.o"))
            if not inputs:
                raise RuntimeError("Build current debug CLI before ownership tests: " + target)
            objects.extend(inputs)
        modules = binary_dir / "Modules"
        cls.binary = folder / "OwnershipHost"
        result = subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-I", str(modules if modules.is_dir() else binary_dir),
            "-Xcc", "-fmodule-map-file=" + str(modulemap),
            str(ROOT / "Tests/AXAutomationRuntime/OwnershipHost.swift"), *map(str, objects), "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ax-owner-", dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.device = "AX-TEST-" + uuid.uuid4().hex

    def command(self, mode, scenario):
        return [str(self.binary), mode, str(self.root), self.device, scenario]

    def start_owner(self, scenario):
        owner = subprocess.Popen(self.command("owner", scenario), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        gate = self.root / "continue"
        def stop():
            gate.touch(exist_ok=True)
            if owner.poll() is None:
                owner.kill()
            owner.communicate(timeout=5)
        self.addCleanup(stop)
        ready = self.root / "ready.json"
        deadline = time.monotonic() + 8
        while not ready.exists():
            if owner.poll() is not None:
                self.fail("Owner exited before helper gate: " + str(owner.communicate()))
            if time.monotonic() >= deadline:
                self.fail("Helper gate timeout")
            time.sleep(0.01)
        details = json.loads(ready.read_text())
        return owner, details

    def admit(self, mode):
        # Both backends use SessionDeviceLock. Use a different state root from the old host.
        result = subprocess.run(self.command("admit", mode), capture_output=True, text=True, timeout=5)
        return result, json.loads(result.stdout)

    def await_admission(self, mode):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result, facts = self.admit(mode)
            if facts.get("acquired"):
                self.assertEqual(result.returncode, 0)
                return
            self.assertEqual(facts["code"], "device_busy")
            time.sleep(0.02)
        self.fail("Device lock did not release after helper exit")

    def test_orphan_disable_blocks_both_modes_before_and_after_validation(self):
        for phase in ("before-validation", "after-validation", "after-write"):
            for successor in ("standard", "runner"):
                with self.subTest(phase=phase, successor=successor):
                    # Isolate every schedule, including journal, gate and fake device identity.
                    self.setUp()
                    owner, details = self.start_owner(phase)
                    owner.kill()
                    owner.communicate(timeout=5)
                    result, facts = self.admit(successor)
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(facts, {"acquired": False, "code": "device_busy"})
                    self.assertTrue(Path(details["journal"]).exists())
                    (self.root / "continue").touch()
                    self.await_admission(successor)
                    self.assertEqual((self.root / "preference").read_text(), "true")
                    self.assertEqual((self.root / "writes").read_text().splitlines(), ["true", "false"])
                    self.assertFalse((self.root / "cleanup.json").exists(), "Dead host cannot claim acknowledged cleanup")

    def test_orphan_notification_retains_control_ownership_after_host_and_helper_die(self):
        owner, details = self.start_owner("notification")
        owner.kill()
        owner.communicate(timeout=5)
        os.kill(details["helperPID"], signal.SIGKILL)
        for successor in ("standard", "runner"):
            result, facts = self.admit(successor)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(facts["code"], "device_busy")
        self.assertTrue(Path(details["journal"]).exists())
        (self.root / "continue").touch()
        self.await_admission("runner")
        self.assertEqual((self.root / "preference").read_text(), "true")
        self.assertFalse((self.root / "cleanup.json").exists())

    def test_timeout_reaps_helper_keeps_pending_and_recovery_is_ordered(self):
        owner, details = self.start_owner("timeout")
        owner.communicate(timeout=6)
        self.assertEqual(owner.returncode, 0)
        cleanup = json.loads((self.root / "cleanup.json").read_text())
        self.assertFalse(cleanup["acknowledged"])
        self.assertTrue(cleanup["cleanupPending"])
        self.assertTrue(Path(details["journal"]).exists())
        self.assertEqual((self.root / "writes").read_text().splitlines(), ["true"])
        (self.root / "continue").touch()
        recovered = subprocess.run(self.command("owner", "complete"), capture_output=True, text=True, timeout=8)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual((self.root / "writes").read_text().splitlines(), ["true", "false", "true", "false"])
        cleanup = json.loads((self.root / "cleanup.json").read_text())
        self.assertTrue(cleanup["acknowledged"])
        self.assertFalse(cleanup["cleanupPending"])
        self.assertFalse(Path(details["journal"]).exists())

    def test_lost_reply_after_disable_is_not_success_and_cannot_affect_successor(self):
        owner, details = self.start_owner("after-write")
        os.kill(details["pid"], signal.SIGKILL)
        owner.communicate(timeout=5)
        self.assertEqual(owner.returncode, 0)
        cleanup = json.loads((self.root / "cleanup.json").read_text())
        self.assertFalse(cleanup["acknowledged"])
        self.assertTrue(cleanup["cleanupPending"])
        self.assertTrue(Path(details["journal"]).exists())
        self.await_admission("runner")
        self.assertEqual((self.root / "preference").read_text(), "true")

    def test_helper_without_inherited_lock_cannot_write(self):
        token = str(uuid.uuid4())
        journal = self.root / "journal.json"
        journal.write_text(json.dumps({"device": self.device, "token": token, "enabled": True}))
        for close_stdin in ("false", "true"):
            with self.subTest(close_stdin=close_stdin):
                result = subprocess.run([
                    str(self.binary), "helper", "--fixture-root", str(self.root), "--scenario", "complete",
                    "--device", self.device, "--journal", str(journal), "--token", token,
                    "--enabled", "true", "--output", str(self.root / "output.json"), "--close-stdin", close_stdin,
                ], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 3)
                self.assertFalse((self.root / "preference").exists())
                self.assertFalse((self.root / "output.json").exists())



if __name__ == "__main__":
    unittest.main()
