#!/bin/zsh
# Renders words across the dictionaries Super Gloss has, as the app does, and reports what
# renders badly: sideways scrolling, missing images, the default face, script errors,
# frames that keep growing or cut off their content. Also renders scripts/render-audit/fixtures.
# With --cards, also shares passages of every entry as Share as Image does, and reports
# any that make no card.
# Usage: scripts/render-audit.sh [--width 1000] [--dark] [--random N] [--only DICT] [--cards]
#                                [--root DIR]… [--words FILE] [--shots DIR] [word…]
set -euo pipefail
cd "${0:A:h}/.."
export PATH="$HOME/.cargo/bin:$PATH"
cargo build -p supergloss-core --release --quiet
bin=target/render-audit/render-audit
src=(scripts/render-audit/main.swift)
if [[ ! -x $bin || $src -nt $bin || target/release/libsupergloss.a -nt $bin ]]; then
  mkdir -p ${bin:h}
  swiftc -O -import-objc-header core/include/supergloss.h -L target/release -lsupergloss \
    -framework WebKit -framework AppKit $src -o $bin
fi
exec $bin "$@"
