#!/bin/sh
# Read-only prerequisites. Device setup and connection remain explicit operations.
set -eu

source_workflow=false
candidate_workflow=false
cli=${IPHONE_USE_CLI:-iphone-use}
case "${1-}" in
  '') ;;
  --source) source_workflow=true ;;
  --candidate) candidate_workflow=true ;;
  *) echo 'Usage: preflight.sh [--source|--candidate]' >&2; exit 64 ;;
esac
if [ "$#" -gt 1 ]; then
  echo 'Usage: preflight.sh [--source|--candidate]' >&2
  exit 64
fi
if [ "$(uname -s)" != Darwin ]; then
  echo 'iPhone-use requires a Mac. Run this plugin on the Mac connected to the iPhone.' >&2
  exit 1
fi
if ! command -v "$cli" >/dev/null 2>&1; then
  if [ -n "${IPHONE_USE_CLI:-}" ]; then
    printf 'Cannot run the configured IPHONE_USE_CLI: %s\n' "$cli" >&2
    exit 1
  fi
  cli="${HOME:-}/.local/bin/iphone-use"
  if [ -z "${HOME:-}" ] || [ ! -f "$cli" ] || [ ! -x "$cli" ]; then
    echo 'iPhone-use CLI not found. Install with: curl -fsSL https://iphone-use.com/install.sh | /bin/sh' >&2
    exit 1
  fi
fi
if ! version=$("$cli" --version); then
  echo 'iPhone-use could not start. Check the complete CLI/Runner installation.' >&2
  exit 1
fi
if [ "$version" = development ] && [ "$source_workflow" = true ]; then
  echo 'Unversioned source CLI: standard needs no Runner; runner requires a supplied signed .xctestrun or setup.'
elif [ "$candidate_workflow" = true ] && printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z][0-9A-Za-z.-]*$'; then
  echo 'Explicit local candidate: no published-release or device-readiness claim.'
elif ! printf '%s\n' "$version" | awk -F. '
  /^[0-9]+\.[0-9]+\.[0-9]+$/ {
    if ($1 > 0 || ($1 == 0 && $2 >= 4)) valid = 1
  }
  END {exit !(valid && NR == 1)}'; then
  echo "Unsupported CLI version: $version. Install stable iPhone-use 0.4.0 or later." >&2
  exit 1
fi
if ! developer_dir=$(xcode-select -p) || [ ! -d "$developer_dir/Platforms/iPhoneOS.platform" ]; then
  echo 'Select full Xcode in Xcode Settings → Locations. Command Line Tools alone are insufficient.' >&2
  exit 1
fi
printf 'iPhone-use CLI: %s\nCLI path: %s\nXcode: %s\n' "$version" "$(command -v "$cli")" "$developer_dir"
tap_help=$("$cli" tap --help)
if printf '%s\n' "$tap_help" | grep -q -- '--observe'; then
  echo 'Action --observe: available. Read action outcome and observation separately.'
else
  echo 'Action --observe: unavailable. Use separate action, completion, and observe calls.'
fi
if printf '%s\n' "$tap_help" | grep -q -- '--agent-output'; then
  echo 'Agent output: available. Use --agent-output for actions and native text preparation/finish; full receipt saved locally.'
fi
if text_help=$("$cli" text-prepare --help 2>/dev/null) && printf '%s\n' "$text_help" | grep -q -- '--field-rect'; then
  echo 'Scoped standard text preparation: available. Use native-text.md before standard input; Runner uses element typing.'
fi
if setup_help=$("$cli" setup --help 2>/dev/null) &&
   printf '%s\n' "$setup_help" | grep -q -- '--preview' &&
   printf '%s\n' "$setup_help" | grep -q -- '--progress'; then
  echo 'Setup preview: available. Read connection-progress.md only if setup is needed.'
fi
connect_help=$("$cli" connect --help)
if printf '%s\n' "$tap_help" | grep -q -- '--evidence-dir' &&
   printf '%s\n' "$connect_help" | grep -q -- '--evidence-dir'; then
  echo 'Native evidence: available. When archival is requested, add --evidence-dir DIR to connect and session commands; use artifacts paths. No output helper needed.'
fi
if printf '%s\n' "$connect_help" | grep -q -- '--reuse'; then
  echo 'Session reuse: available. Use connect --reuse; record reused/lifecycle. Borrowed sessions and their preview remain running at task completion unless explicitly asked to disconnect. sessions lists existing endpoints.'
fi
if printf '%s\n' "$connect_help" | grep -q -- '--progress'; then
  echo 'Connection progress: available. Use --progress; relay human-action events and resume the same execution.'
fi
if printf '%s\n' "$connect_help" | grep -q -- '--mode'; then
  echo 'Control modes: available. Honor saved mode unless the user explicitly selects standard or runner.'
fi
if preview_help=$("$cli" preview --help 2>/dev/null) &&
   printf '%s\n' "$preview_help" | grep -q -- '--no-open' &&
   printf '%s\n' "$preview_help" | grep -q -- '--stop'; then
  echo 'Live preview: available. After connect, follow the shared live-preview lifecycle once per owned session unless the user opted out.'
  if printf '%s\n' "$preview_help" | grep -q -- '--device'; then
    echo 'Independent preview: available. preview --device UDID needs no control session or Runner. Control disconnect does not stop it; use explicit preview --device UDID --stop for an owned preview unless continued viewing was requested.'
  fi
  if printf '%s\n' "$preview_help" | grep -q -- '--port'; then
    echo 'Preview port: configurable. Default 8765; preview --port PORT overrides one start; config set preview-port PORT saves a default. On preview_port_in_use, follow the bounded same-session port recovery in live-preview.md.'
  fi
else
  echo 'Live preview: unavailable. Continue phone control without preview; do not automatically upgrade or switch the selected CLI.'
fi
echo 'Next: iphone-use devices. A successful preflight does not validate device trust or signing.'

if "$cli" focus --help >/dev/null 2>&1 && "$cli" clear --help >/dev/null 2>&1; then
  echo 'Explicit Runner actions: available. Type directly when current evidence confirms field focus; otherwise focus and inspect. Read runner-actions.md for editing workflows.'
fi
