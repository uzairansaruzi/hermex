#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Pinned build tool only; no runtime npm dependencies or network at app launch.
npm exec --yes --package=esbuild@0.25.12 -- esbuild \
  HermesMobile/Resources/BotDesktop.bundle/bridge.js \
  --bundle --format=esm --target=safari16 --minify --legal-comments=eof \
  --banner:js='(async () => {' --footer:js='})();' \
  --outfile=HermesMobile/Resources/BotDesktop.bundle/viewer.js
