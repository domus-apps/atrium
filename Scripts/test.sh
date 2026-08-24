#!/bin/bash
# Runs the unit tests. Kept as the stable entry point even though it is now a
# passthrough — with full Xcode installed, plain `swift test` needs no extra
# flags. (Command Line Tools alone can't run Swift Testing.)
set -euo pipefail
cd "$(dirname "$0")/.."

swift test "$@"
