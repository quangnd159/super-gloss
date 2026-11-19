#!/bin/zsh
# Builds Super Gloss.app (Release). Usage: ./build.sh [Debug|Release]
set -euo pipefail
cd "${0:A:h}"
config=${1:-Release}
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

command -v cargo >/dev/null || { echo "cargo not found: install Rust from https://rustup.rs" >&2; exit 1; }
cargo test -p supergloss-core --release --quiet

cd app
if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
elif [[ ! -d SuperGloss.xcodeproj ]]; then
  echo "xcodegen not found (brew install xcodegen)" >&2; exit 1
fi
xcodebuild -project SuperGloss.xcodeproj -scheme SuperGloss -configuration "$config" \
  -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build -quiet

echo "Built: $PWD/build/DerivedData/Build/Products/$config/Super Gloss.app"
