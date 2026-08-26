#!/bin/bash
# Prints the CHANGELOG.md section for <version> (heading excluded).
# Fails if the section is missing or empty, so a release without notes
# stops before anything is built or published.
#
# Usage: changelog-extract.sh <version>   (no leading v, e.g. 1.1.0)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$1

NOTES=$(awk -v ver="$VERSION" '
  /^## / { in_section = ($2 == ver); next }
  in_section { print }
' CHANGELOG.md)

if [[ -z "${NOTES//[[:space:]]/}" ]]; then
    echo "error: CHANGELOG.md has no section '## $VERSION'" >&2
    exit 1
fi

printf '%s\n' "$NOTES"
