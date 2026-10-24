# Explicit Runner actions

Runner action protocol 13 separates device execution from agent decisions. Update the CLI and Runner together, disconnect old hosts and reconnect. New CLI action requests use host protocol 2 so an old host rejects them instead of silently auto-focusing. Standard mode retains its separately documented screenshot/HID contract.

## Ownership

The tool checks the current session, app/alert scope and target identity, executes one explicit primitive, and reports facts. The agent interprets the page, chooses targets after navigation, verifies selections and text, and decides subsequent actions. Neither layer should replay an uncertain action without inspecting its actual effects.

`observe` gets new AX and screenshot data; the two captures are not atomic. `inspect` reads cached evidence only. A new observation invalidates old action references. Each action consumes its observation-local identity table. Input is not a database transaction: it cannot roll back partial edits or prevent all external UI races.

## Targets and action-specific checks

Element actions resolve a fresh root snapshot. Each observed ancestor identity must still exist in the same parent chain, but its sibling index, label, value and frame may change. Under each already identified parent, exactly one direct child must match the expected native AX identity. Missing, duplicate, reparented or replaced identities reject; there is no global name/type fallback. The selected snapshot is bound to an executable element, checked again, and validated against another fresh root snapshot. Platform identity reuse and the final check-to-event race remain limitations.

| Action | Current conditions | Result and agent responsibility |
| --- | --- | --- |
| `focus oN:eN` | Enabled input; hittable if a tap is needed | Already focused is a verified no-op. Otherwise tap once and read focus. A changed page or unconfirmed focus returns verification facts; never retap automatically. |
| `type oN:eN --text TEXT` | Enabled input owns keyboard focus; supported literal text | Insert once at the existing caret/selection. No implicit focus, clearing, movement or final-value assertion. Inspect the result. `--mode insert` is optional; Runner replace/append modes reject before dispatch. |
| `press oN:eN --key KEY` | Enabled input owns keyboard focus | Send one key. Return/Tab may submit or move focus; never require the old page/focus afterward. `select-all` and `end` request Command-A and Command-Down; they do not certify a selection. |
| `clear oN:eN` | Focused, non-secure input; current readable value agrees with the new observation | After the agent selects all and inspects the selection, send Delete once. Report whether the field is empty. Partial selection may delete only part of the text; never repair or repeat deletion automatically. Empty fields are a verified no-op. |
| Element tap/double-tap/long-press | Enabled, currently hittable identity | Use the current element, not its old screenshot center. Observe resulting navigation. |
| Element swipe | Enabled, hittable container identity and direction | Use the current element's 20%–80% path and requested velocity/holds. Use a coordinate swipe for explicit endpoints. |
| Coordinate gestures | Current screen/scope/orientation, valid points and strict local protected pixels | No AX identity guarantee. Runner's default global change limit is 1; local limit remains 0. Standard retains global 0.01. Explicit thresholds and dynamic target/anchor checks remain available. |
| Home | Current session and app/alert context | Acknowledge system navigation; do not require unchanged pixels or infer a business destination. |
| App lifecycle | Valid bundle, protected-app restrictions and lifecycle facts | Foreground process does not prove page readiness. Observe separately. |

Keyboard input does not require hittability when the selected target already owns focus. Parameters still reject unsupported control keys and text beyond 4096 UTF-8 bytes; LF requires a text view, and Runner CR/CRLF remain unsupported. Secure text is never reconstructed for clearing/append.

## Replacement and append workflows

Use actual current references at every step; these examples are a sequence of agent decisions, not a batch script.

Replacement:

1. `focus oN:eN --observe`; inspect the image and focus verification.
2. `press CURRENT --key select-all --observe`; verify the intended selection visually.
3. `clear CURRENT --observe`; require an empty field before continuing. `inputAction.verification=confirmed` confirms only the bounded read, not future stability.
4. `type CURRENT --text 'new text' --observe`; inspect the full resulting text.

Append:

1. Focus and inspect.
2. `press CURRENT --key end --observe`; verify the insertion point is at the end and the original text is intact.
3. Insert only the suffix with `type`, then inspect.

There is no general selected-range API in this implementation. If the current screenshot/AX cannot establish the required selection or end position, stop or choose a different visible UI action. Do not assume shortcut acknowledgement proves its effect. Never implement append by clearing and rewriting the original text.

## Execution, verification and observation

`execution.started` is set before an event API. `inputAction.eventAttempted` and `eventAcknowledged` describe the single focus/type/clear event; a verified no-op has both false. `inputAction.verification` is `confirmed`, `unconfirmed`, `unavailable` or `not_requested`. Verification failure after an acknowledged event does not erase acknowledgement. Focus/clear callers must inspect this field rather than treating `completed` as goal completion.

Post-action image sampling is separate. A missing or invalid frame is reported in `result.observationError`; it does not replay input or turn an acknowledged event into a non-dispatch claim. `--observe` returns separate action and observation results. Its combined exit can be nonzero even when the action completed. Read both results.

The tool never automatically repeats events on transport errors, verification failures or capture failures. A partial/lost response means input may have occurred. Apple APIs can internally perform work; a single tool call is not a universal exactly-once delivery guarantee. The agent must retain partial progress instead of restarting replacement from its first step.

## Validation

Shared tests cover sibling changes, wrong identity binding, reparenting, duplicate identities, focus/no-op, input rejection, incomplete clearing, read failures and no replay. Host/CLI tests cover mode rejection, protocol compatibility, observation errors and action-specific target construction. Device acceptance must separately cover Probe, Settings and Xiaohongshu with the exact CLI and installed Runner; a host test is not physical-device evidence.
