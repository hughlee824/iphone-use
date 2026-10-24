# Explicit Runner actions

Requires CLI 0.4.0 with action protocol 13 and its matching Runner. Preflight must report `Explicit Runner actions: available`; otherwise upgrade and reconnect rather than guessing old semantics. Standard mode retains its native-text reference.

Every example uses a placeholder CURRENT from the latest successful observation. Read its image before the next input; do not execute these as a batch.

- Focus: `focus CURRENT --observe`. Inspect `result.inputAction.verification` and the image. Already focused is a no-op. A tap may navigate; choose a new target from the new page, never retry focus blindly.
- Insert: `type CURRENT --text TEXT --observe`. Requires that exact target to own keyboard focus; does not tap, clear or position. Input is sent once. Check actual text; no final-value guarantee.
- Replace: focus and inspect; `press CURRENT --key select-all --observe`; verify selection; `clear CURRENT --observe`; require empty field; then type and inspect. Clear sends one Delete only, never selects or repairs incomplete selection. A missing pre-input AX value rejects as `clear_value_unavailable`; it does not prove emptiness. Do not continue unless emptiness is confirmed.
- Append: focus and inspect; `press CURRENT --key end --observe`; verify end position and unchanged original text; type only the suffix and inspect. If the end/selection cannot be established visually or from AX, stop or choose a visible UI operation. Never clear/rewrite to append.
- Editing keys require the specified field to own focus. Return/Tab may submit or change focus; inspect before proceeding.
- Element gestures bind the current identity, not the old center. Coordinates require current screenshot geometry and protected local pixels. Runner's global threshold defaults to 1, local to 0; standard defaults are unchanged. Neither proves business identity.

Sibling insertion/removal and layout changes are allowed while the original ancestor identity chain remains. Replacement, reparenting or ambiguity reject instead of selecting a similar element. New observations invalidate old references.

Execution and observation are independent. `completed` confirms execution or a verified no-op, not business success. `inputAction.verification=unconfirmed/unavailable` means focus/clear effects need inspection. `observationError` or a failing combined `--observe` exit must not trigger another input. `unknown` may include partial input: inspect actual contents and preserve progress. Never restart the entire replace workflow after a late failure. No automatic replay or cross-app identity fallback.
