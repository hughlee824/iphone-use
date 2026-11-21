"""Offline diagnostics UX, with an isolated state root and no device commands."""
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest
from zipfile import ZipFile

CLI = Path(os.environ.get("IPHONE_USE_TEST_CLI", Path(__file__).resolve().parents[2] / ".build/debug/iphone-use"))


@unittest.skipUnless(CLI.is_file(), "Build the CLI before integration tests")
class DiagnosticsCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="diagnostic-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.state = self.root / "state"
        self.env = {**os.environ, "IPHONE_USE_STATE_DIR": str(self.state),
                    "IPHONE_USE_CONFIG_DIR": str(self.root / "config")}

    def call(self, *args, success=True):
        result = subprocess.run([str(CLI), "diagnostics", *args], env=self.env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stderr or result.stdout)
        return json.loads(result.stdout)

    def test_shared_config_updates_preserve_mode_and_sparse_preferences(self):
        folder = Path(self.env["IPHONE_USE_CONFIG_DIR"])
        file = folder / "config.json"
        defaults = self.call("config")["result"]
        self.assertFalse(file.exists())
        folder.mkdir(mode=0o700)
        legacy = '{"version":1,"mode":"runner"}'
        file.write_text(legacy)
        self.assertEqual(self.call("config")["result"], defaults)
        self.assertEqual(file.read_text(), legacy)

        prefs = self.call("config", "--evidence", "off")["result"]
        self.assertEqual(prefs, {**defaults, "captureEvidence": False})
        self.assertEqual(json.loads(file.read_text()), {
            "version": 1, "mode": "runner", "diagnostics": {"captureEvidence": False}})
        mode = [str(CLI), "config", "set", "mode", "standard"]
        # Another process holds the same lock between read and write. Both writers must fail cleanly.
        before = file.read_bytes()
        with (folder / "device-configuration.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            blocked = subprocess.run(mode, env=self.env, capture_output=True, timeout=10)
            self.assertNotEqual(blocked.returncode, 0)
            self.assertEqual(json.loads(blocked.stdout)["error"]["code"], "configuration_busy")
            self.assertEqual(self.call("config", "--level", "warn", success=False)["error"]["code"],
                             "configuration_busy")
            self.assertEqual(file.read_bytes(), before)
        subprocess.run(mode, env=self.env, capture_output=True, timeout=10, check=True)
        self.assertEqual(self.call("config")["result"], prefs)
        self.call("config", "--level", "warn")
        self.assertEqual(json.loads(file.read_text()), {
            "version": 1, "mode": "standard", "diagnostics": {"captureEvidence": False, "level": "warn"}})
        self.assertFalse((folder / "diagnostics.json").exists())

    def test_each_diagnostic_field_can_be_the_only_override(self):
        folder = Path(self.env["IPHONE_USE_CONFIG_DIR"])
        folder.mkdir(mode=0o700)
        defaults = {"level": "info", "captureEvidence": True, "historyDays": 7,
                    "evidenceHours": 24, "evidenceMiB": 100}
        for overrides in [{}, {"level": "debug"}, {"captureEvidence": False}, {"historyDays": 3},
                          {"evidenceHours": 2}, {"evidenceMiB": 8}]:
            with self.subTest(overrides=overrides):
                file = folder / "config.json"
                raw = json.dumps({"version": 1, "mode": "runner", "diagnostics": overrides})
                file.write_text(raw)
                self.assertEqual(self.call("config")["result"], {**defaults, **overrides})
                self.assertEqual(file.read_text(), raw)

    def test_settings_and_export_without_phone(self):
        self.assertEqual(self.call("config")["result"]["level"], "info")
        opts = self.call("config", "--level", "warn", "--evidence", "off", "--evidence-mib", "4")["result"]
        self.assertFalse(opts["captureEvidence"])
        self.assertEqual(opts["evidenceMiB"], 4)
        self.call("config", "--level", "verbose", success=False)
        self.assertEqual(self.call("config")["result"], opts)
        archive = self.root / "report.zip"
        response = self.call("export", "--last-session", "--output-file", archive, success=False)
        self.assertEqual(response["error"]["code"], "diagnostics_not_found")
        self.assertFalse(archive.exists())
        # The Swift host tests exercise writing. Here verify the shipping CLI's default and selected ZIP members.
        session = "s" + "a" * 32
        now = time.time()
        with sqlite3.connect(self.state / "diagnostics/history.sqlite3") as database:
            database.execute("INSERT INTO sessions VALUES(?,?,?,1)", (session, now, now))
            for ref in ["o1", "o2"]:
                database.execute("INSERT INTO frames(session,ref,time,bytes,png) VALUES(?,?,?,?,?)",
                                 (session, ref, now, 3, b"png"))
        self.call("export", "--last-session", "--output-file", archive)
        with ZipFile(archive) as plain:
            self.assertEqual(set(plain.namelist()), {"manifest.json", "timeline.jsonl"})
        selected = self.root / "selected.zip"
        self.call("export", "--session", session, "--frame", "o2", "--output-file", selected)
        with ZipFile(selected) as evidence:
            self.assertEqual(evidence.read("o2/screen.png"), b"png")
            self.assertNotIn("o1/screen.png", evidence.namelist())
        missing = self.root / "missing.zip"
        response = self.call("export", "--session", session, "--frame", "o3", "--output-file", missing, success=False)
        self.assertEqual(response["error"]["code"], "diagnostics_frame_unavailable")
        self.assertFalse(missing.exists())
