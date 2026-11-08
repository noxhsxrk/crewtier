#!/usr/bin/env bash
# Install crewtier without npm or git:
#   curl -fsSL https://raw.githubusercontent.com/noxhsxrk/crewtier/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/noxhsxrk/crewtier/main/install.sh | bash -s -- init --all
# From a git checkout it links that checkout instead (handy while developing):
#   ./install.sh
# Anything after the script name is passed to `crewtier` once installed (e.g. init --scope project).
set -euo pipefail
REPO="noxhsxrk/crewtier"
REF="${CREWTIER_REF:-main}"
STATE="$HOME/.crewtier"; APP="$STATE/app"
BINDIR="${CREWTIER_BIN_DIR:-$HOME/.local/bin}"

here=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi

mkdir -p "$BINDIR"
if [[ -n "$here" && -f "$here/bin/crewtier" ]]; then
  target="$here"                                   # local checkout
else
  command -v curl >/dev/null || { echo "curl is required"; exit 1; }
  command -v tar >/dev/null || { echo "tar is required"; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  echo "Downloading $REPO@$REF …"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$tmp"
  src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  mkdir -p "$STATE"; rm -rf "$APP"; mv "$src" "$APP"
  target="$APP"
fi
chmod +x "$target/bin/crewtier" "$target"/scripts/*.sh
ln -sf "$target/bin/crewtier" "$BINDIR/crewtier"
echo "✓ crewtier → $BINDIR/crewtier ($target)"

for dep in git jq; do command -v "$dep" >/dev/null || echo "! $dep not found — install it (macOS: brew install $dep)"; done
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "! $BINDIR is not on your PATH. Add this to your shell profile:"
     echo "    export PATH=\"$BINDIR:\$PATH\"" ;;
esac

if [[ $# -gt 0 ]]; then
  echo; exec "$BINDIR/crewtier" "$@"
else
  echo; echo "Next: crewtier init"
fi
