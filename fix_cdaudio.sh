#!/bin/bash
# 修复 CD 音频回调缓冲区溢出：
# CDAudioCallBack 按整扇区(2352B)往 8KB 的 player.buffer 追加数据，
# 但请求量 len 无上限；音频欠载后的"补偿"大块请求会写穿缓冲区，
# 用光盘音轨数据踩烂相邻的 mixer.channels 指针 → MIXER_CallBack 野指针崩溃。
# 修法：把单次 len 钳制在 buffer 容量减一个扇区内，不足部分由混音器自动分次补齐。
#
# 注：后来 ASan 证明本次崩溃的真凶是 GFX_EndUpdate（见 fix_gfx.sh），本补丁
# 并非崩溃原因，但它修的是真实的健壮性问题，保留。
set -e
cd "$(dirname "$0")"
python3 - <<'PYEOF'
import io, sys
p = "dospad/dosbox/src/dos/cdrom_image.cpp"
src = io.open(p, encoding="utf-8").read()
if "idos-cd-fix" in src:
    print("已修过，跳过"); sys.exit(0)

a = "\tlen *= 4;       // 16 bit, stereo\n\tif (!len) return;\n"
assert a in src, "找不到 CDAudioCallBack 锚点"
b = ("\tlen *= 4;       // 16 bit, stereo\n"
     "\tif (!len) return;\n"
     "\t/* idos-cd-fix: clamp request so sector-sized appends can never overflow player.buffer */\n"
     "\tif (len > sizeof(player.buffer) - RAW_SECTOR_SIZE) {\n"
     "\t\tlen = sizeof(player.buffer) - RAW_SECTOR_SIZE;\n"
     "\t\tlen &= ~(Bitu)3;\n"
     "\t}\n")
src = src.replace(a, b, 1)
io.open(p, "w", encoding="utf-8").write(src)
print("cdrom_image.cpp 修复完成")
PYEOF
echo "✅ 完成。回到 Xcode ⌘R 重新运行。"
