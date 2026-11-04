#!/bin/bash
# One-command installer for ModelThumbs.
#
#   curl -fsSL https://raw.githubusercontent.com/enzoballardin/model-thumbs/main/install.sh | bash
#
# Downloads (or updates) the source into ~/.modelthumbs and runs build.sh with --yes,
# so STEP/IGES support is included automatically when Homebrew is available.
# Extra arguments are passed to build.sh, e.g. "| bash -s -- --no-cad".

set -euo pipefail

REPO="https://github.com/enzoballardin/model-thumbs.git"
DIR="${MODELTHUMBS_DIR:-$HOME/.modelthumbs}"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }

bold "ModelThumbs installer"

# Apple's Command Line Tools provide git and the Swift compiler.
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are required. A dialog will open to install them."
  echo "When it finishes, run this same command again."
  xcode-select --install 2>/dev/null || true
  exit 1
fi

if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
  echo "Note: Homebrew isn't installed, so STEP/IGES thumbnails will be skipped."
  echo "      Install it from https://brew.sh and run this command again to add them."
fi

if [ -d "$DIR/.git" ]; then
  echo "Updating source in $DIR"
  git -C "$DIR" fetch --depth 1 origin
  git -C "$DIR" reset --hard origin/HEAD
else
  rm -rf "$DIR"
  echo "Downloading source to $DIR"
  git clone --depth 1 "$REPO" "$DIR"
fi

cd "$DIR"
if [ "$#" -eq 0 ]; then set -- --yes; fi
exec bash build.sh "$@"
