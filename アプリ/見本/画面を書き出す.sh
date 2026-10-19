#!/bin/bash
# 作り物の状態で、全部の画面を画像に書き出す（41 枚・数十秒）。本物のデータ（~/GitHub取得データ）には触らない
# 使い方: bash アプリ/見本/画面を書き出す.sh <画像の出力先>
#   先に bash アプリ/build.sh で組み立てておく
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
OUT="${1:?画像の出力先を指定してください}"
BIN="$APP_DIR/build/GitHub取得.app/Contents/MacOS/GitHubFetch"
[ -x "$BIN" ] || { echo "先に bash アプリ/build.sh で組み立ててください"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/base" "$OUT"
touch "$WORK/base/github.py"                                  # 取得の仕組みのフォルダの印（中身は使わない）
/usr/bin/python3 "$HERE/見本の状態.py" "$WORK/data" >/dev/null # 作り物の状態フォルダ
"$BIN" --snapshot "$OUT" -baseDir "$WORK/base" -dataDir "$WORK/data" | grep -c '^書き出し' | sed 's/^/書き出した枚数: /'
if [ -e "$HOME/GitHub取得データ" ]; then echo "（~/GitHub取得データ はもともとあります。この台本は触っていません）"; fi
