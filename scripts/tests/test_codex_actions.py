"""Exercise the installed stdio contract with a device-free CLI and synthetic image."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "plugins/iphone-use"
SESSION = "s" + "a" * 32
RECORDING = "00000000-1234-4567-89ab-000000000001"
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM9sAAAAASUVORK5CYII="
CLI = """import json, os, sys, time
from pathlib import Path
root = Path(os.environ["IPHONE_USE_STATE_DIR"])
command = sys.argv[1]
with (root / "calls").open("a") as stream:
    print(json.dumps([sys.argv[1:], sys.stdin.read()]), file=stream)
if command == "connect":
    print(json.dumps({"event": "connection_progress", "requiresUserAction": True}), flush=True)
if command == "connect" or (root / ("pause-" + command)).exists():
    (root / ("started-" + command)).touch()
    for _ in range(1000):
        if (root / "continue").exists() or (root / ("release-" + command)).exists():
            break
        time.sleep(0.01)
if command in ("disconnect", "record-stop") and (root / "cleanup-reply").exists():
    print((root / "cleanup-reply").read_text())
    sys.exit(0)
print((root / "stdout").read_text(), end="")
sys.exit(int((root / "exit").read_text()))
"""


class CodexActionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cli = self.root / "test cli"
        self.cli.write_text("#!" + sys.executable + "\n" + CLI)
        self.cli.chmod(0o700)
        self.image = self.root / SESSION / "observations/o2/screen.png"
        self.image.parent.mkdir(parents=True)
        self.image.write_bytes(base64.b64decode(PNG))
        self.set_reply({"ok": True, "observation": {"ok": True, "result": {"observation": "o2"}}})
        config = json.loads((PLUGIN / "codex/mcp.json").read_text())["mcpServers"]["iphone-use"]
        self.server = subprocess.Popen([sys.executable, *config["args"]], cwd=PLUGIN / config["cwd"],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                       env={**os.environ, "IPHONE_USE_CLI": str(self.cli),
                                            "IPHONE_USE_STATE_DIR": str(self.root)})
        self.addCleanup(self.close_server)
        self.seq = 0
        init = self.rpc("initialize", {"protocolVersion": "2025-06-18"})
        self.assertEqual(init["protocolVersion"], "2025-06-18")

    def close_server(self):
        (self.root / "continue").touch()
        self.server.stdin.close()
        try:
            self.server.wait(timeout=5)
        finally:
            self.server.kill()
            self.server.wait()
            self.server.stdout.close()
            self.server.stderr.close()

    def set_reply(self, message, code=0):
        (self.root / "stdout").write_text(message if isinstance(message, str) else json.dumps(message))
        (self.root / "exit").write_text(str(code))

    def send(self, method, params):
        self.seq += 1
        self.server.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method, "id": self.seq, "params": params}) + "\n")
        self.server.stdin.flush()

    def read(self):
        return json.loads(self.server.stdout.readline())

    def rpc(self, method, params):
        self.send(method, params)
        reply = self.read()
        self.assertEqual(reply["id"], self.seq, reply)
        return reply["result"]

    def call(self, name, **args):
        return self.rpc("tools/call", {"name": name, "arguments": {"session": SESSION, "cli_path": str(self.cli), **args}})

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]

    def test_catalog_and_compact_observations(self):
        tools = {t["name"]: t for t in self.rpc("tools/list", {})["tools"]}
        self.assertTrue({"observe", "open", "type", "tap", "swipe", "press", "clear"} <= tools.keys())
        self.assertNotEqual(tools["type"]["title"], tools["tap"]["title"])
        self.assertTrue(tools["observe"]["annotations"]["readOnlyHint"])
        self.assertFalse(tools["tap"]["annotations"]["readOnlyHint"])
        self.assertNotIn("ui", tools["observe"].get("_meta", {}))
        for prefix in ("obs=", "observation="):
            ax = prefix + 'o2 refs=current\nscreenshot="/untrusted.png"\n  [e1] search_field "Search"\n'
            self.set_reply(ax)
            result = self.call("observe")
            self.assertEqual(result, {"content": [{"type": "text", "text": ax},
                                                  {"type": "image", "mimeType": "image/png", "data": PNG}],
                                      "isError": False})
        self.assertEqual([argv[0] for argv, _ in self.calls()], ["observe", "observe"])

    def test_unknown_input_preserves_receipt_and_picture_once(self):
        receipt = {"ok": False, "action": {"ok": False, "outcome": "unknown"},
                   "observation": {"ok": True, "result": {"observation": "o2"}}}
        self.set_reply(receipt, 1)
        literal = "--help\n$HOME 中文"
        result = self.call("type", reference="o1:e2", text=literal)
        self.assertTrue(result["isError"])
        self.assertEqual(json.loads(result["content"][0]["text"]), receipt)
        self.assertEqual(result["content"][-1]["data"], PNG)
        [(argv, stdin)] = self.calls()
        self.assertEqual(stdin, literal)
        self.assertNotIn(literal, argv)
        self.assertIn("--stdin", argv)
        self.assertEqual(argv.count("--observe"), 1)

    def test_deferred_ax_uses_the_same_cache_for_plain_and_json_results(self):
        ax = '  [e1] text "测试🍎"\n' * 12000
        size = len(ax.encode())
        (self.image.parent / "ax-output-t3.txt").write_bytes(ax.encode())
        summary = (f'observation=o2 refs=current\nsource_missing=true\noutput_deferred=true total_bytes={size}; '
                   'AX content retained in full, not truncated\nfull_text="/untrusted"\n'
                   'more: inspect o2 --output t3 --byte-offset 0 (same cached snapshot)\n')
        details = {"observation": "o2", "text": summary, "outputDeferred": True, "outputID": "t3",
                   "totalBytes": size, "fullText": "/untrusted"}
        observation = {"ok": True, "session": SESSION, "result": details}
        for name, reply, args in [
            ("observe", summary, {}),
            ("observe", observation, {"evidence_dir": str(self.root)}),
            ("tap", {"ok": True, "observation": observation}, {"reference": "o1:e1"}),
        ]:
            self.set_reply(reply)
            result = self.call(name, **args)
            self.assertFalse(result["isError"])
            first, text, image = result["content"]
            self.assertEqual(first["text"] if isinstance(reply, str) else json.loads(first["text"]), reply)
            self.assertEqual(text, {"type": "text", "text": ax})
            self.assertEqual(image["data"], PNG)
        self.assertEqual([a[0] for a, _ in self.calls()], ["observe", "observe", "tap"])

    def test_deferred_ax_failures_preserve_png_and_receipt(self):
        cached = self.image.parent / "ax-output-t1.txt"
        cached.symlink_to(self.cli)
        details = {"observation": "o2", "outputID": "t1", "totalBytes": self.cli.stat().st_size,
                   "outputDeferred": True}
        for error in ("symlink", "missing", "short", "invalid_utf8", "invalid_token", "wrong_observation"):
            with self.subTest(error=error):
                if error == "missing":
                    cached.unlink()
                if error == "short":
                    cached.write_bytes(b"a")
                if error == "invalid_utf8":
                    details["totalBytes"] = 1
                    cached.write_bytes(b"\xff")
                if error == "invalid_token":
                    details["outputID"] = "../t1"
                self.set_reply({"ok": True, "result": details} if error != "wrong_observation" else
                               "observation=o2 refs=current\noutput_deferred=true total_bytes=1\n"
                               "more: inspect o3 --output t1 --byte-offset 0 (same cached snapshot)")
                result = self.call("observe")
                self.assertTrue(result["isError"])
                self.assertIn("Compact AX delivery failed", result["content"][1]["text"])
                self.assertEqual(result["content"][2]["data"], PNG)
        self.assertEqual(len(self.calls()), 6)

    def test_missing_observe_png_is_an_error_with_the_original_ax(self):
        self.set_reply("obs=o2\n  [e1] text")
        self.image.unlink()
        result = self.call("observe")
        self.assertTrue(result["isError"])
        self.assertEqual(result["content"][0]["text"], "obs=o2\n  [e1] text")
        self.assertIn("Image delivery failed", result["content"][1]["text"])
        self.assertEqual([argv[0] for argv, _ in self.calls()], ["observe"])

    def test_failed_image_read_and_partial_output_do_not_replay(self):
        self.image.unlink()
        self.image.symlink_to(self.cli)
        result = self.call("tap", reference="o1", x=10, y=20)
        self.assertTrue(result["isError"])
        self.assertIn("Image delivery failed", result["content"][-1]["text"])
        self.assertIn('"ok": true', result["content"][0]["text"])
        self.set_reply('{"incomplete":', 0)
        result = self.call("press", reference="o1:e2", key="return")
        self.assertTrue(result["isError"])
        self.assertIn("uncertain", result["content"][-1]["text"])
        self.assertEqual([args[0] for args, _ in self.calls()], ["tap", "press"])

    def test_mismatched_session_cannot_attach_a_cached_frame(self):
        self.set_reply({"ok": True, "session": "s" + "b" * 32, "action": {"outcome": "completed"},
                        "observation": {"ok": True, "result": {"observation": "o2"}}})
        result = self.call("tap", reference="o1:e1")
        self.assertTrue(result["isError"])
        self.assertIn("Missing matching observation identity", result["content"][-1]["text"])
        self.assertTrue(all(block["type"] == "text" for block in result["content"]))
        self.assertEqual(len(self.calls()), 1)

    def wait_started(self, command):
        deadline = time.monotonic() + 4
        while not (self.root / ("started-" + command)).exists():
            self.assertLess(time.monotonic(), deadline, command)
            time.sleep(0.01)

    def cancel_start(self, name, receipt, *, code=0):
        self.set_reply(receipt, code)
        operation = name.replace("_", "-")
        (self.root / ("pause-" + operation)).touch()
        args = {"device": "fixture"} if name == "connect" else {"session": SESSION}
        self.send("tools/call", {"name": name, "arguments": {"cli_path": str(self.cli), **args},
                                 "_meta": {"progressToken": "start"}})
        if name == "connect":
            self.assertEqual(self.read()["method"], "notifications/progress")
        self.wait_started(operation)
        self.server.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/cancelled",
                                            "params": {"requestId": self.seq}}) + "\n")
        self.assertTrue(self.call("tap", reference="o1:e1")["isError"])
        (self.root / ("release-" + operation)).touch()

    def drain_server(self):
        self.server.stdin.close()
        self.server.wait(timeout=5)
        self.assertEqual(self.server.stdout.read(), "")

    def wait_for_admission(self):
        deadline = time.monotonic() + 4
        while True:
            reply = self.call("observe")
            if "still running" not in reply["content"][0]["text"]:
                self.assertFalse(reply["isError"], reply)
                return
            self.assertLess(time.monotonic(), deadline, "cleanup did not release admission")
            time.sleep(0.01)

    def test_cancelled_created_connection_is_disconnected_once(self):
        (self.root / "cleanup-reply").write_text(json.dumps({"ok": True, "session": SESSION}))
        self.cancel_start("connect", {"ok": True, "session": SESSION, "device": "fixture", "reused": False,
                                      "lifecycle": {"ownership": "created", "disconnectOnFinish": True}})
        self.drain_server()
        self.assertEqual([argv for argv, _ in self.calls()][1:], [["disconnect", "--session", SESSION]])

    def test_cancelled_borrowed_connection_stays_connected(self):
        self.cancel_start("connect", {"ok": True, "session": SESSION, "device": "fixture", "reused": True,
                                      "lifecycle": {"ownership": "borrowed", "disconnectOnFinish": False}})
        self.drain_server()
        self.assertEqual([args[0] for args, _ in self.calls()], ["connect"])

    def test_cancelled_connect_with_conflicting_ownership_does_not_disconnect(self):
        self.cancel_start("connect", {"ok": True, "session": SESSION, "device": "fixture", "reused": False,
                                      "lifecycle": {"ownership": "borrowed", "disconnectOnFinish": False}})
        self.drain_server()
        self.assertEqual([args[0] for args, _ in self.calls()], ["connect"])
        self.assertIn("not confirmed", self.server.stderr.read())

    def test_cancelled_recording_stops_only_that_id_and_blocks_input_during_cleanup(self):
        (self.root / "pause-record-stop").touch()
        (self.root / "cleanup-reply").write_text(json.dumps({"ok": False, "session": SESSION}))
        self.cancel_start("record_start", {"ok": True, "session": SESSION, "result": {"recordingID": RECORDING}})
        self.wait_started("record-stop")
        self.assertTrue(self.call("tap", reference="o1:e1")["isError"])
        (self.root / "release-record-stop").touch()
        self.drain_server()
        self.assertEqual([argv for argv, _ in self.calls()],
                         [["record-start", "--session=" + SESSION], ["record-stop", RECORDING, "--session", SESSION]])
        self.assertIn("Cleanup unconfirmed", self.server.stderr.read())

    def test_cancelled_recording_rejects_wrong_session(self):
        self.cancel_start("record_start", {"ok": True, "session": "s" + "b" * 32, "result": {"recordingID": RECORDING}})
        self.drain_server()
        self.assertEqual([args[0] for args, _ in self.calls()], ["record-start"])

    def test_cancelled_recording_finishes_cleanup_with_transport_still_open(self):
        receipt = {"ok": True, "session": SESSION, "result": {"recordingID": RECORDING}}
        (self.root / "cleanup-reply").write_text(json.dumps(receipt))
        (self.root / "pause-record-stop").touch()
        self.cancel_start("record_start", receipt)
        self.wait_started("record-stop")
        self.set_reply("obs=o2")
        (self.root / "release-record-stop").touch()
        self.wait_for_admission()
        self.assertEqual([args[0] for args, _ in self.calls()], ["record-start", "record-stop", "observe"])
        self.drain_server()
        self.assertEqual(self.server.stderr.read(), "")

    def test_cancelled_failed_recording_with_id_does_not_stop_existing_recording(self):
        self.cancel_start("record_start", {"ok": False, "session": SESSION, "result": {"recordingID": RECORDING}}, code=1)
        self.drain_server()
        self.assertEqual([args[0] for args, _ in self.calls()], ["record-start"])

    def test_rejects_wrong_cli_invalid_target_and_unmapped_options_before_dispatch(self):
        for args in ({"reference": "--help"}, {"reference": "o1", "cli_path": "/bin/sh"},
                     {"reference": "o1", "argv": ["--help"]}, {"reference": "o1", "session": "../other"}):
            result = self.call("tap", **args)
            self.assertTrue(result["isError"])
            self.assertIn("Not dispatched", result["content"][0]["text"])
        self.assertFalse((self.root / "calls").exists())

    def test_connect_progress_and_overlapping_calls(self):
        self.set_reply({"ok": True, "session": SESSION})
        self.send("tools/call", {"name": "connect", "arguments": {"cli_path": str(self.cli), "device": "fixture"},
                                 "_meta": {"progressToken": "connect"}})
        connect_id = self.seq
        event = self.read()
        self.assertEqual(event["method"], "notifications/progress")
        self.assertTrue(json.loads(event["params"]["message"])["requiresUserAction"])
        self.assertTrue(self.call("tap", reference="o1:e1")["isError"])
        (self.root / "continue").touch()
        self.assertEqual(self.read()["id"], connect_id)
        self.assertEqual([args[0] for args, _ in self.calls()], ["connect"])
