# Local diagnostic history

Standard and Runner hosts keep a per-user history automatically. Run `iphone-use diagnostics config` to see the settings. By default the log threshold is `info`, timeline retention is seven days, and key screenshots and available AX nodes are retained locally for 24 hours with a shared 100 MiB evidence payload budget per state root. No extra device captures are requested. Connect/status reports the host's actual diagnostic level and local evidence setting.

```sh
iphone-use diagnostics config --level debug
iphone-use diagnostics config --evidence off
iphone-use diagnostics config --level info --evidence on --history-days 7 --evidence-hours 24 --evidence-mib 100
```

Preferences live under the optional `diagnostics` field of `~/.iphone-use/config.json`. A mode-only configuration still works. Each omitted field uses its own default. For example, this file turns off local screen and AX retention while keeping the other defaults:

```json
{"version": 1, "mode": "standard", "diagnostics": {"captureEvidence": false}}
```

Reading the preferences leaves the file untouched. Mode and diagnostic updates share one configuration lock. Changing the mode preserves diagnostic settings. Changing diagnostics preserves the saved mode, or resolves the usual initial mode when creating the file. Older CLI versions that only accept `version` and `mode` cannot read a file with a `diagnostics` field.

These preferences apply to newly started hosts. A reused host keeps its existing settings. Switching evidence off allows ordinary observations and in-memory target checks to continue. It does not erase previous history. Logs use debug, info, warn and error in increasing severity. Debug adds numeric stage timings. Info includes the operation, source observation, coordinates or element number, final outcome and available dispatch/verification facts. Warn includes target rejections and screenshot fallback. Error includes failed capture and unconfirmed cleanup. Each level includes higher severities. An admitted action without a final record has an unknown outcome. A sent input without a device acknowledgement is still uncertain. Timeline records omit input text, clipboard contents, labels, screenshots, raw request/response dictionaries and device identifiers. Operational host stderr, explicit developer traces, and full receipts requested with `--agent-output` or `--evidence-dir` remain separate.

## Export a report after disconnect

The exporter works offline and creates a private ZIP file. Choose a new path in an existing directory. With multiple phones, use the specific session ID instead of the latest session.

```sh
iphone-use diagnostics export --last-session --output-file report.zip
iphone-use diagnostics export --session "$SESSION" --frame o17 --frame o18 --output-file selected.zip
iphone-use diagnostics export --session "$SESSION" --include-evidence --output-file full.zip
```

The default archive contains a redacted timeline and an index of available frame references. Open `manifest.json` to see what is still available and `timeline.jsonl` for events in host order. Only explicit frame selection or `--include-evidence` includes screen contents. Review these locally before sharing. Nothing is uploaded. Keep the ZIP in a task-owned location and delete it separately when finished.

Within one session, follow the action's `sourceObservation` to what the agent saw. `guardFrame` identifies the last actual standard pre-input PNG when retained. A rejected frame may share its observation ID. `observation` identifies the returned image and available AX, with role `after`, `rejection` or `observe`. Runner's separate follow-up observation carries the originating request ID in `followingAction`. Another request may intervene between them. Each available frame has a PNG; its optional AX JSON contains captured nodes and geometry. Screenshot and AX have separate acquisition times when the source supplies them. The exporter never refreshes an old frame. A frame saved earlier may have been evicted, and some guards do not capture a PNG. The manifest lists what actually survived. An explicitly requested missing frame fails the export.

## Retention and cleanup

The local store uses Apple's system SQLite under `$IPHONE_USE_STATE_DIR/diagnostics` (default state root `/private/tmp/iphone-use-<uid>`). The suffix `<uid>` is the numeric ID of the macOS user running the CLI, available with `id -u`. Each user gets a separate private state directory. History and diagnostic copies are separate from the live observation cache, device ownership and recovery state. The evidence cap measures PNG and AX payload bytes, excluding the database index, timeline and SQLite journal overhead.

Lifecycle maintenance removes expired records only from sessions with confirmed cleanup. If disconnect reports pending recovery, that session keeps its existing frames and events. While capturing a new frame, an active host may evict its own older frames or frames from confirmed closed sessions. A new frame may be omitted if protected data occupies the budget. Expired protected data can remain on disk. Export still enforces the configured age limits. There is no background deletion service while the tool is idle.

```sh
iphone-use diagnostics clean
iphone-use diagnostics clean --apply
```

The first command previews expired events, frames and eligible legacy action journals. The second removes eligible history. Legacy plaintext `native-events.jsonl` requires an identified, expired session with a matching terminal receipt, confirmed cleanup and no socket. Empty legacy folders cannot prove ownership has ended and are left alone. Device locks, AX recovery journals, session configuration, preview data and explicitly exported bundles are outside this cleanup. The diagnostic store does not migrate old raw logs into shareable reports.
