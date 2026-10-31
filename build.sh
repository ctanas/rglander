#!/bin/sh
# Build distributable packages into dist/:
#   rglander.love             run anywhere with LOVE 11.x:  love rglander.love
#   rglander_vX.Y.Z_portmaster.zip   unzip into the "ports" folder of the handheld's SD card
set -e
cd "$(dirname "$0")"

VERSION=$(sed -n 's/^ *VERSION = "\(.*\)",$/\1/p' src/core.lua)
[ -n "$VERSION" ] || { echo "cannot read VERSION from src/core.lua" >&2; exit 1; }

rm -rf dist
mkdir -p dist/stage/rglander/gamedata

zip -9 -q -r dist/rglander.love main.lua conf.lua src -x '*.DS_Store'

cp -R main.lua conf.lua src dist/stage/rglander/gamedata/
cp "port/RG Lander.sh" dist/stage/
chmod +x "dist/stage/RG Lander.sh"
(cd dist/stage && zip -9 -q -r "../rglander_v${VERSION}_portmaster.zip" "RG Lander.sh" rglander -x '*.DS_Store')
rm -rf dist/stage

echo "built:"
ls -l dist
