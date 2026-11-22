"""Codex stdio tools. The installed iPhone-use CLI owns all device operations."""
import base64
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading


# Names double as CLI option names (underscores become hyphens).
NUMBERS = set("x y from_x from_y to_x to_y velocity press_duration hold_duration duration "
              "from_distance to_distance max_screen_change max_region_change".split())
GUARDS = "max_screen_change max_region_change protect ignore_rect dynamic_target dynamic_anchor"
FIELD = "field_rect caret_rect ignore_rect"
TOOLS = {}


def tool(name, title, required="", optional="", *, positional=None, after=False, description=None):
    fields = ["cli_path", "device" if name == "connect" else "session", *required.split()]
    properties = {}
    for key in fields + optional.split() + ["evidence_dir"]:
        if key in NUMBERS:
            schema = {"type": "number"}
        elif key == "protect":
            schema = {"type": "array", "items": {"type": "string"}, "maxItems": 3}
        else:
            schema = {"type": "string"}
        properties[key] = schema
    properties["cli_path"]["description"] = "Absolute CLI path from this task's preflight."
    properties["evidence_dir"]["description"] = "Absolute private archive directory, only when requested."
    if "reference" in properties:
        properties["reference"]["description"] = "Current oN or oN:eN from this session's observation."
    definition = {"name": name, "title": title, "description": description or title + ". Follow the iPhone-use skill.",
                  "inputSchema": {"type": "object", "properties": properties, "required": fields,
                                  "additionalProperties": False},
                  "annotations": {"title": title, "readOnlyHint": name == "observe",
                                  "idempotentHint": False}}
    TOOLS[name] = definition, positional, after


tool("observe", "Observe iPhone screen",
     description="Capture a fresh screenshot and Compact AX for this session. This read-only observation "
                 "sends no touch or keyboard input and never repeats the preceding action.")
tool("open", "Open iPhone app", "bundle_id", positional="bundle_id", after=True)
for name, title in [("tap", "Tap iPhone screen"), ("double_tap", "Double-tap iPhone screen"),
                    ("long_press", "Long-press iPhone screen")]:
    options = "x y " + GUARDS
    if name == "long_press":
        options += " duration"
    tool(name, title, "reference", options, positional="reference", after=True)
tool("swipe", "Swipe iPhone screen", "reference",
     "direction from_x from_y to_x to_y velocity press_duration hold_duration " + GUARDS,
     positional="reference", after=True)
tool("pinch", "Pinch iPhone screen", "reference x y from_distance to_distance",
     "duration " + GUARDS, positional="reference", after=True)
tool("home", "Go to iPhone Home Screen", "reference", positional="reference", after=True)
tool("type", "Type text on iPhone", "reference text", "mode method " + FIELD, positional="reference", after=True)
tool("press", "Press iPhone key", "reference key", FIELD, positional="reference", after=True)
tool("focus", "Focus iPhone field", "reference", positional="reference", after=True)
tool("clear", "Clear selected iPhone text", "reference", positional="reference", after=True)
tool("text_prepare", "Prepare iPhone keyboard", optional="field_rect ignore_rect")
tool("text_finish", "Finish verified iPhone paste", "reference transaction", positional="reference")
tool("connect", "Connect to iPhone")
tool("disconnect", "Disconnect from iPhone")
tool("record_start", "Start iPhone recording", optional="duration")
tool("record_stop", "Stop iPhone recording", "recording_id", positional="recording_id")


class NotDispatched(ValueError):
    """The CLI has not been started."""


def validate(name, args):
    schema = TOOLS[name][0]["inputSchema"]
    if not isinstance(args, dict) or not set(schema["required"]) <= args.keys() <= schema["properties"].keys():
        raise NotDispatched("Missing or unexpected tool arguments")
    for key, value in args.items():
        kind = schema["properties"][key]["type"]
        if kind == "number":
            valid = type(value) in (float, int) and math.isfinite(value)
        elif kind == "array":
            valid = isinstance(value, list) and len(value) <= 3 and all(
                isinstance(ref, str) and re.fullmatch(r"o[0-9]+:e[0-9]+", ref) for ref in value)
        else:
            valid = isinstance(value, str) and "\0" not in value
        if not valid:
            raise NotDispatched(f"Invalid {key}")
    for key, pattern in (("session", r"s[0-9a-f]{32}"), ("reference", r"o[1-9][0-9]*(?::e[0-9]+)?"),
                         ("bundle_id", r"[A-Za-z0-9][A-Za-z0-9.-]*"), ("recording_id", r"[A-Za-z0-9-]+")):
        if key in args and not re.fullmatch(pattern, args[key]):
            raise NotDispatched(f"Invalid {key}")
    if "evidence_dir" in args and not os.path.isabs(args["evidence_dir"]):
        raise NotDispatched("evidence_dir must be absolute")
    configured = shutil.which(os.getenv("IPHONE_USE_CLI") or "iphone-use")
    if not configured or not os.path.isabs(args["cli_path"]) or not os.path.isabs(configured):
        raise NotDispatched("The server needs the installed CLI on PATH or an absolute IPHONE_USE_CLI")
    executable = Path(configured).resolve()
    if executable != Path(args["cli_path"]).resolve():
        raise NotDispatched("Server CLI differs from preflight. Configure the same CLI before starting.")
    return str(executable)


def command(name, args, cli):
    _, positional, after = TOOLS[name]
    operation = name.replace("_", "-")
    argv = [cli, operation]
    if positional:
        argv.append(args[positional])
    for key, value in args.items():
        if key in ("text", "cli_path", positional):
            continue
        for item in value if isinstance(value, list) else [value]:
            argv.append(f"--{key.replace('_', '-')}={item}")
    if name == "type":
        argv.append("--stdin")
    if name == "connect":
        argv.extend(["--reuse", "--progress"])
    if after:
        argv.append("--observe")
    if after or name in ("text_prepare", "text_finish"):
        # The skill checks CLI capabilities before choosing this adapter.
        argv.append("--agent-output")
    return argv


def content(text):
    return {"type": "text", "text": text}


def cached_bytes(session, observation, filename, expected_size=None):
    # Only open the CLI's session-owned cache entry, never paths in AX text/tool arguments.
    root = Path(os.getenv("IPHONE_USE_STATE_DIR") or f"/private/tmp/iphone-use-{os.getuid()}")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    directory = os.open(root, flags)
    try:
        for component in (session, "observations", observation):
            child = os.open(component, flags, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, "rb") as stream:
            meta = os.fstat(fd)
            if not stat.S_ISREG(meta.st_mode):
                raise ValueError("Invalid observation cache file")
            if expected_size is not None and meta.st_size != expected_size:
                raise ValueError("Cached AX byte count changed")
            data = stream.read()
            if expected_size is not None and len(data) != expected_size:
                raise ValueError("Incomplete AX cache file")
            return data
    finally:
        os.close(directory)


def deferred_ax(session, observed, details, stdout):
    if details is not None:
        if details.get("outputDeferred") is not True:
            return None
        token, size = details.get("outputID"), details.get("totalBytes")
    else:
        # Only the CLI's deferred-output envelope carries a cache token. Ignore AX
        # labels and the printed file path; derive the filename within this observation.
        lines = stdout.rstrip("\n").split("\n")
        offset = 2 if lines[1:2] == ["source_missing=true"] else 1
        if (not lines[0].startswith("observation=") or len(lines) <= offset
                or not lines[offset].startswith("output_deferred=true ")):
            return None
        header = re.match(r"output_deferred=true total_bytes=(\d+)\b", lines[offset])
        more = re.fullmatch(rf"more: inspect {observed} --output (t[1-9][0-9]*) --byte-offset 0 \(same cached snapshot\)", lines[-1])
        if not header or not more:
            raise ValueError("Missing matching AX continuation")
        token, size = more[1], int(header[1])
    if not isinstance(token, str) or not re.fullmatch(r"t[1-9][0-9]*", token) or type(size) is not int or size < 0:
        raise ValueError("Invalid AX cache identity or size")
    return cached_bytes(session, observed, f"ax-output-{token}.txt", size).decode("utf-8")


def result_for(name, args, code, stdout, stderr):
    blocks = [content(stdout)] if stdout else []
    if stderr:
        blocks.append(content(stderr))
    try:
        reply = json.loads(stdout)
    except ValueError:
        reply = None
    observed = None
    details = None
    expects_image = name == "observe" and code == 0
    if isinstance(reply, dict) and "session" in args:
        observation = reply.get("observation", reply if name == "observe" else {})
        if isinstance(observation, dict) and observation.get("ok") is True:
            expects_image = True
            details = observation.get("result", {})
            session = args["session"]
            if (isinstance(details, dict) and reply.get("session", session) == session
                    and observation.get("session", session) == session):
                observed = details.get("observation")
    elif name == "observe" and code == 0:
        # Plain observe prints compact AX. Only trust its anchored identity header.
        match = re.match(r"(?:obs|observation)=(o[1-9][0-9]*)\b", stdout)
        if match:
            observed = match[1]
    failed = code != 0
    if failed:
        blocks.append(content(f"CLI exit status: {code}. Inspect the receipt before deciding the next action."))
    if isinstance(observed, str) and re.fullmatch(r"o[1-9][0-9]*", observed) and "session" in args:
        try:
            ax = deferred_ax(args["session"], observed, details, stdout)
            if ax is not None:
                blocks.append(content(ax))
        except (ValueError, OSError) as error:
            failed = True
            blocks.append(content(f"Compact AX delivery failed: {error}. Inspect the same cached observation."))
        try:
            png = cached_bytes(args["session"], observed, "screen.png")
            if not png.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("Invalid PNG")
            blocks.append({"type": "image", "mimeType": "image/png", "data": base64.b64encode(png).decode("ascii")})
        except (ValueError, OSError) as error:
            failed = True
            blocks.append(content(f"Image delivery failed: {error}. Read the existing image; do not recapture or replay input."))
    elif expects_image:
        failed = True
        blocks.append(content("Missing matching observation identity. Inspect the existing receipt; never repeat input."))
    if name != "observe" and (not isinstance(reply, dict) or type(reply.get("ok")) is not bool):
        failed = True
        blocks.append(content("No complete CLI receipt. Execution is uncertain. Never replay the operation."))
    return {"content": blocks, "isError": failed}


def invoke(name, args, cli, progress, token, launch):
    argv = command(name, args, cli)
    if name != "connect":
        with launch(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            stdout, stderr = process.communicate(args.get("text", "").encode())
            return process.returncode, stdout.decode(errors="replace"), stderr.decode(errors="replace")
    if token is None:
        raise NotDispatched("Connect needs progress delivery. Use the skill's streaming shell connection.")
    # Forward authorization prompts while connect is pending. Keep stderr out of the JSON stream.
    with tempfile.TemporaryFile() as errors, launch(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=errors) as process:
        lines = []
        count = 0
        for line in process.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                event = None
            if isinstance(event, dict) and event.get("event") == "connection_progress":
                count += 1
                progress(token, count, json.dumps(event, ensure_ascii=False))
            else:
                lines.append(line)
        code = process.wait()
        errors.seek(0)
        return code, b"".join(lines).decode(errors="replace"), errors.read().decode(errors="replace")


def release_cancelled_start(cli, name, args, code, stdout):
    if name not in ("connect", "record_start"):
        return
    # Only the final successful start receipt establishes ownership. A progress
    # event, an error carrying status, or a later device inventory cannot do so.
    receipt = json.loads(stdout)
    if code or not isinstance(receipt, dict) or receipt.get("ok") is not True:
        raise ValueError("Start did not return a confirmed successful receipt")
    session = receipt.get("session")
    if not isinstance(session, str) or not re.fullmatch(r"s[0-9a-f]{32}", session):
        raise ValueError("Missing session identity")
    if name == "connect":
        lifecycle = receipt.get("lifecycle")
        if receipt.get("reused") is True:
            return
        if (receipt.get("device") != args["device"] or receipt.get("reused") is not False
                or not isinstance(lifecycle, dict) or lifecycle.get("ownership") != "created"
                or lifecycle.get("disconnectOnFinish") is not True):
            raise ValueError("Missing matching created-session receipt")
        cleanup = [cli, "disconnect", "--session", session]
    else:
        facts = receipt.get("result")
        recording = facts.get("recordingID") if isinstance(facts, dict) else None
        if (session != args["session"] or not isinstance(recording, str)
                or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", recording)):
            raise ValueError("Missing matching recording identity")
        cleanup = [cli, "record-stop", recording, "--session", session]
    released = subprocess.run(cleanup, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        ack = json.loads(released.stdout)
        confirmed = isinstance(ack, dict) and ack.get("session") == session and ack.get("ok") is True
        if confirmed and name == "record_start":
            facts = ack.get("result")
            confirmed = isinstance(facts, dict) and facts.get("recordingID") == recording
    except ValueError:
        confirmed = False
    if released.returncode or not confirmed:
        raise ValueError(f"Cleanup unconfirmed for {cleanup[1:]}")


def serve():
    output_lock = threading.Lock()
    dispatch_lock = threading.Lock()
    active_id = None
    cancelled = False

    def send(message):
        with output_lock:
            print(json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=True), flush=True)

    def progress(token, count, message):
        nonlocal cancelled
        with dispatch_lock:
            if not cancelled:
                try:
                    send({"method": "notifications/progress", "params": {"progressToken": token, "progress": count,
                                                                         "message": message}})
                except BrokenPipeError:
                    cancelled = True

    def launch(argv, **streams):
        with dispatch_lock:
            if cancelled:
                raise NotDispatched("Request cancelled before CLI startup")
            try:
                return subprocess.Popen(argv, **streams)
            except OSError as error:
                raise NotDispatched(str(error)) from error

    def execute(request_id, params):
        nonlocal active_id
        raw = None
        try:
            name = params.get("name")
            if not isinstance(name, str) or name not in TOOLS:
                raise NotDispatched("Unknown iPhone-use tool")
            token = params.get("_meta", {}).get("progressToken")
            args = params.get("arguments", {})
            cli = validate(name, args)
            raw = invoke(name, args, cli, progress, token, launch)
            result = result_for(name, args, *raw)
        except NotDispatched as error:
            result = {"content": [content(f"Not dispatched: {error}")], "isError": True}
        except Exception as error:
            result = {"content": [content(f"Execution uncertain: {error}. Never replay the operation.")], "isError": True}
        with dispatch_lock:
            if not cancelled:
                try:
                    send({"id": request_id, "result": result})
                    active_id = None
                    return
                except BrokenPipeError:
                    pass
        # Keep admission closed while cleanup is outstanding, without blocking
        # the reader from handling cancellations or rejecting overlapping input.
        try:
            if raw is not None:
                release_cancelled_start(cli, name, args, raw[0], raw[1])
        except (ValueError, OSError) as error:
            print(f"Cancelled {name}: {error}. Cleanup was not confirmed; no retry.", file=sys.stderr, flush=True)
        finally:
            with dispatch_lock:
                active_id = None

    for line in sys.stdin.buffer:
        try:
            request = json.loads(line)
        except ValueError:
            send({"id": None, "error": {"code": -32700, "message": "Invalid JSON"}})
            continue
        if not isinstance(request, dict):
            send({"id": None, "error": {"code": -32600, "message": "Invalid request"}})
            continue
        method, params, request_id = request.get("method"), request.get("params", {}), request.get("id")
        if request_id is None:
            if method == "notifications/cancelled" and isinstance(params, dict):
                with dispatch_lock:
                    if active_id is not None and active_id == params.get("requestId"):
                        # A running CLI may have sent input. Drain it before admitting another action.
                        cancelled = True
            continue
        if not isinstance(params, dict):
            send({"id": request_id, "error": {"code": -32602, "message": "Expected object parameters"}})
            continue
        if method == "initialize":
            version = params.get("protocolVersion")
            if version not in ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"):
                version = "2025-11-25"
            result = {"protocolVersion": version, "capabilities": {"tools": {}},
                      "serverInfo": {"name": "iphone-use", "version": "1"}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": [entry[0] for entry in TOOLS.values()]}
        elif method == "tools/call":
            # Never queue a second action behind unresolved input (including cancellation).
            with dispatch_lock:
                if active_id is None:
                    active_id = request_id
                    cancelled = False
                    threading.Thread(target=execute, args=(request_id, params)).start()
                    continue
            result = {"content": [content("Not dispatched: another iPhone tool is still running.")], "isError": True}
        else:
            send({"id": request_id, "error": {"code": -32601, "message": "Unknown method"}})
            continue
        send({"id": request_id, "result": result})
    with dispatch_lock:
        cancelled = True  # The client closed the transport before receiving the result.


if __name__ == "__main__":
    serve()
