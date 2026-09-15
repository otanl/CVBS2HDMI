#!/bin/bash
# Keep the existing entry point. No caller-supplied glob is ever deleted.
set -euo pipefail
exec python3 "$(dirname "$0")/live_capture.py" "$@"
