#!/usr/bin/env bash
# Ships a new version: pushes main and a version tag. GitHub Actions then
# builds, signs, notarizes and publishes it, and installed copies of Simmer
# offer the update by themselves.
#
#   ./scripts/ship.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: ship.sh VERSION   (for example 0.2.0)}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 1.2.3" >&2; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "error: switch to main first." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: commit your changes first." >&2; exit 1; }
git fetch -q origin --tags
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "error: v$VERSION already exists. Pick a higher version." >&2
  exit 1
fi
LATEST=$(git tag --list 'v*' --sort=-v:refname | head -1)
echo "Latest release: ${LATEST:-none}. Shipping v$VERSION."

git push origin main
git tag -a "v$VERSION" -m "Simmer $VERSION"
git push origin "v$VERSION"

echo
echo "GitHub is building v$VERSION now. Follow it here:"
echo "  https://github.com/barry-napier/simmer/actions/workflows/release.yml"
echo "When it finishes, Simmer offers the update to everyone within a day,"
echo "or straight away from Check for Updates… in the menu."
