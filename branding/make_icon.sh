#!/bin/bash
# 从你自己那份游戏里重新生成 branding/icon-1024.png。
#
# 图标是游戏自带的官方图标（盾牌 + 立狮纹章），藏在 HEROES2W.EXE 的 PE 资源段里，
# 原始只有 32x32 / 16 色。sips 解 4bpp 调色板会解错（颜色全泛白），所以是自己解码
# 再用纯 Python 写 PNG，32 倍最近邻放大到 1024（整数倍 → 像素边缘锐利），配深蓝渐变底。
#
# 仓库里不放这张成品图 —— 它是游戏的美术资源，不适合跟着开源仓库分发。
# 你在本地跑一次就有了，fix_branding.sh 需要它。
#
# 用法： bash branding/make_icon.sh [HEROES2 目录]
#   默认从套件根目录的 英雄无敌2.idos/HEROES2/ 里找
set -e
cd "$(dirname "$0")/.."

GAMEDIR="${1:-英雄无敌2.idos/HEROES2}"
EXE="$GAMEDIR/HEROES2W.EXE"
[ -f "$EXE" ] || { echo "错误：找不到 $EXE"; echo "用法: bash branding/make_icon.sh [HEROES2 目录]"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> 1/3 从 PE 资源段抽出 RT_ICON"
python3 branding/exico.py "$EXE" "$WORK/official.ico" 0

echo "==> 2/3 解 4bpp 调色板 → 像素矩阵"
# icodec.py / mkicon.py 用的是固定的 /tmp 中转路径，这里照搬
cp "$WORK/official.ico" /tmp/official.ico
python3 branding/icodec.py

echo "==> 3/3 放大 32 倍 + 深蓝渐变底 → 1024x1024"
python3 branding/mkicon.py
cp /tmp/icon_emblem.png branding/icon-1024.png
rm -f /tmp/official.ico /tmp/icon_px.pkl /tmp/icon_emblem.png

echo ""
echo "✅ branding/icon-1024.png 已生成"
sips -g pixelWidth -g pixelHeight -g hasAlpha branding/icon-1024.png 2>/dev/null | grep -E "pixel|Alpha"
