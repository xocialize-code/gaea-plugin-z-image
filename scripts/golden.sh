#!/bin/zsh
# The plugin against in-process MLXServeEngine: images made on the signed bundle the way Gaea runs them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through zimage-inproc with the
# lane configuration and the request the worker uses. Each pair must be the same PNG, byte for byte.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases, all at seed 42: NitroFusion2 at its default two steps (int4 and bf16, 1024²), at one step and at four (int4,
# 768×512), and Z-Image Turbo at 512² as the control that 0.2.0 left it alone.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/z-image.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-/Volumes/DEV_VOL1/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product zimage-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/zimage-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# Z-Image golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
PROMPT="a red fox sitting in a snowy forest at sunrise, photorealistic"
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' | awk '!seen[$0]++' }

# case <name> <model> <lane> <width> <height> [steps]
case_() {
  local name=$1 model=$2 lane=$3 w=$4 h=$5 steps=${6:-}
  local params="{\"size\":{\"width\":$w,\"height\":$h},\"count\":1}" ext=()
  [[ -n $steps ]] && ext=(--model-params "{\"x-zimage.steps\":$steps}")
  $CHECK $B --operation image.generate --model $model --lane $lane --seed 42 --params $params $ext --text "prompt=$PROMPT" \
    --models-root "$MODELS" --budget 64000000000 --timeout 900 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(outputs $OUT/$name-gpp.log | head -1); [[ -f $file ]] && cp $file $OUT/$name-gpp.png
  $INPROC --model $model --lane $lane --width $w --height $h ${steps:+--steps} ${steps:+$steps} --seed 42 --prompt "$PROMPT" \
    --models-root "$MODELS" --out $OUT/$name-inproc.png 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  local a=$(shasum -a 256 $OUT/$name-gpp.png 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $OUT/$name-inproc.png 2>/dev/null | cut -c1-16)
  local dims=$(sips -g pixelWidth -g pixelHeight $OUT/$name-gpp.png 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')
  if [[ -n $a && $a == $b && $dims == ${w}x${h} ]]; then pass=$((pass+1)); say "PASS  $name: the same PNG, sha256 $a…, $dims"
  else fail=$((fail+1)); say "FAIL  $name: $a… / $b…, $dims (want ${w}x${h})"; fi
}

case_ nf2-int4 z-image-nitrofusion2 int4 1024 1024
case_ nf2-bf16 z-image-nitrofusion2 bf16 1024 1024
case_ nf2-1step z-image-nitrofusion2 int4 768 512 1
case_ nf2-4step z-image-nitrofusion2 int4 768 512 4
case_ turbo z-image-turbo int4 512 512

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
