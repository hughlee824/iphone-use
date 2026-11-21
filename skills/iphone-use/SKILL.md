---
name: iphone-use
description: Operate apps on a connected physical iPhone using the iPhone-use CLI. Use when the user asks to use iPhone-use or perform an iPhone UI task. Does not cover desktop or browser automation, or development of iPhone-use itself.
---

# iPhone-use

Use the local CLI to observe and act on the iPhone. The agent chooses actions and verifies results; execution receipts alone do not prove task success. Workflow version: **0.3.1**; requires CLI **0.4.0+**.

## Start

1. Run `sh scripts/preflight.sh` relative to this skill's absolute directory. Read the relevant adapter in the same tool invocation when possible: [Codex](references/codex-calls.md), [Claude Code](references/claude-code.md), [DeepSeek Harness](references/deepseek-harness.md), or [other clients](references/generic-agent.md). Preflight checks local capabilities, not phone readiness. Honor an explicitly supplied `IPHONE_USE_CLI`; use `--candidate` for prereleases or `--source` for development builds. Keep the same executable throughout.
2. Run `devices`, then `connect --device DEVICE_ID --reuse --progress` with the returned physical UDID and supported flags. A successful connection already includes status. Record `session`, `mode`, `modeSource`, `reused` and `lifecycle`. Never obtain a session ID from another task's files. A conflict needs diagnosis, not killing another host.
3. Keep the saved control mode. Do not add a mode override, change configuration, or automatically switch backends. Runner uses XCTest/AX; standard uses screenshots/HID with read-only AX when available. Standard AX element references are for `inspect`, not element actions; use screenshot-bound coordinates and the standard text workflow.
4. Default to [live preview](references/live-preview.md) before the first observation, unless the user declined it. **When preview is declined, skip its startup and reference entirely.** Preview is separate from control; keep its ownership record if started.

Before starting Runner, tell the user to keep the phone unlocked and complete Enable UI Automation **if it appears**. With `--progress`, stream messages using short tool yields. Relay `requiresUserAction=true` promptly, identifying authorization only from accompanying evidence; keep waiting on the original execution handle. Slowness alone does not establish a prompt. Read [connection progress](references/connection-progress.md) only for authorization trouble, setup or early preview.

## Observe, choose, verify

Discover unknown bundle IDs using `apps --query NAME`; use returned IDs, not guesses. Use the installed app's displayed name when known. A localized query with no matches may need the alternate displayed name; no match is not a connection diagnosis.

Commands below follow `--session SESSION`:

| Intent | Command |
| --- | --- |
| Open and observe | `open BUNDLE_ID --observe --agent-output` |
| Tap an observed Runner element | `tap oN:eN --observe --agent-output` |
| Tap a screenshot target | `tap oN --x X --y Y --observe --agent-output` |
| Capture without input | `observe` |
| Search the captured AX tree | `inspect oN --query TEXT` |
| Release an owned session | `disconnect` |

Use `--agent-output` only where preflight advertises it; it is not a global flag. `--observe` returns separate action and observation facts. **Read the attached PNG before selecting the next action**, including after a nonzero exit. Do not add another capture when the returned observation is usable. `inspect` searches cached data and cannot revive stale references.

An observation pairs AX and PNG under one ID; it is **not an atomic snapshot**. Standard requests AX and one screenshot in parallel; Runner currently collects them serially. Read both: use AX for labels, structure and known states, and the PNG for layout, overlays and content absent from AX. Acquisition times are request bounds, not device sampling instants; host and device clocks are distinct. Reobserve when conflicting evidence prevents identifying the current target, not for harmless clock or scanning animations. AX failure retains the screenshot. Standard still uses screenshot-bound coordinates; Runner's element actions retain their live checks.

Compact AX omits unknown enabled and keyboard-focus states. Missing state attributes mean unknown, never an implicit true/false or permission to act. Known enabled states appear as `enabled=true` or `disabled`; known focus appears as `keyboard_focus=true/false`. Indentation follows the nearest retained ancestor after redundant layout wrappers are folded; `inspect` preserves captured attributes and original hierarchy. Identical names can still refer to different controls.

Standard compact AX starts with `obs` and observation flags. Standalone compact text files add a coordinate legend on the second line. Its unnumbered `[app]` root gives the AX source app and screen bounds when known. Screenshot-only output omits this root. In `@x,y,w,h`, the four values are left, top, width, and height in screen points. For every node, including indented children, `x` is the distance right and `y` the distance down from the screen’s top-left corner. Pass the chosen tap point to `tap oN --x X --y Y` using the same absolute screen coordinates. `clip=` gives the geometrically exposed portion, with separate rectangles divided by a vertical bar. Neither box proves tappability; confirm the target on the attached PNG. In `[e12?]`, the suffix marks unknown AX visibility. Inspect that node with `oN:e12`.

Observe returns the full compact text; inspect pages contain complete attributes. Oversized results set `outputDeferred=true` and provide `fullText` plus `nextRead`. Follow `inspect oN --output tN --byte-offset N` against the same cached observation; concatenate `content` fields (not the annotated `text`) for exact UTF-8 reconstruction. Use each response's current `refs`, never infer action validity from an archived file. Output files are temporary; `--evidence-dir` archives them. `outputError` means presentation delivery failed, not that phone input should be replayed.

- `completed`: execution completed or verified no-op; inspect the actual UI result.
- `prepared`: clipboard staged, no text inserted; continue the returned touch-paste workflow.
- `unknown`: input may have occurred. Inspect without replaying it.
- `not_dispatched`: no input sent. Correct the evidenced cause; a current attached observation satisfies `requiresObservation`.

Partial output is pending: resume the same execution handle, never restart the command to recover its result. Observation/image-read failure cannot erase action facts. After uncertain or partial text, establish actual contents before any new input; never automatically resend the original text.

Screenshot dimensions are pixels; input uses `screen_points`. Map against the image dimensions actually displayed. After navigation, keyboard/layout changes or scrolling, reselect targets and geometry from the new image. Keep default guards. For `screen_changed`, `stale_observation`, continuous animation or dynamic taps, read [screen guards](references/screen-guards.md) before changing guard options. `stable=false` is a usable but unsettled frame, not failed input or permission to replay.

## Text

**Runner:** prefer `type CURRENT --text TEXT --observe --agent-output` without `--method`. A current `keyboard_focus=true` on the exact input establishes observed focus; the backend still checks live identity and focus before dispatch. If focus is not established, use `focus CURRENT --observe`, inspect, then type using the new reference. Never infer focus solely from a visible keyboard. `textMethods: ["touch-paste"]` lists an optional method, not the default element typing capability.

Read [Runner editing](references/runner-actions.md) for replace/append/clear/selection/keys. Runner has no implicit replace or append. Read [touch paste](references/touch-paste.md) only for an explicit request or concrete direct-input incompatibility/no usable AX target. Language, emoji and length alone do not justify fallback; uncertain input never justifies replay via another method.

**Standard:** read [native text](references/native-text.md) before first text input, prepare its keyboard once, then use fresh field evidence. Read [wheels](references/wheels.md) only for picker-wheel work.

## Evidence and finish

When evidence is requested, preserve the returned screenshot, snapshot and receipt together before the next device action; the cache keeps only two observations and disconnect removes it. When preflight advertises native evidence, append `--evidence-dir DIR` to connect and session commands; use returned `artifacts` paths. Older CLIs can use the fixed output helper described in the Codex adapter. Call the CLI directly; do not generate execution wrappers. Retain connection mode evidence from the existing receipt. Archive only to the requested private directory; ordinary tasks need no extra reports.

Verify requested fields and the resulting saved/sent UI. Continue authorized work; do not impose a fixed route, extra reopening step or cleanup the user did not request. For feed cutoffs, establish the actual date boundary; a relative label alone may be insufficient.

For a **created** session, disconnect and inspect its cleanup acknowledgement. A complete acknowledgement needs no extra status or process query; investigate only missing/failed cleanup. For a **borrowed** session, leave it running unless the user requests disconnect. Release only owned preview/recording resources; newer independent previews need their own explicit stop. Report unresolved execution or cleanup honestly.

For setup, missing CLI, discovery timeouts or other access failures, read [access recovery](references/access-recovery.md). Do not preload recovery references during normal execution.
