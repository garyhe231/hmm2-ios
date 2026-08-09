#!/bin/bash
# 混音器健壮性补丁（搜源码里的 idos-fix）：
#
# ① MIXER_AddChannel / MIXER_DelChannel 改链表时没有任何同步，而
#    MIXER_CallBack 在 SDL 音频线程上同时遍历 mixer.channels。加 SDL_LockAudio
#    把链表改动与回调互斥（mixer.cpp 别处本来就是这个模式）。
# ② 新建的 MixerChannel 没清 done/needed，带着未初始化的值就挂进链表，
#    MIXER_CallBack 的 "chan->done > reduce" 判断会读到垃圾。
# ③ MIXER_CallBack 的 overflow 分支里 mixer.done - 2*mixer.min_needed 是无符号
#    减法。当 max_needed < 2*min_needed 时 mixer.done 可以小于 2*min_needed，
#    结果下溢成 2^64 级的巨值，reduce 随之失控。钳到 0。
#
# 注：ASan 后来证明真凶是 GFX_EndUpdate（见 fix_gfx.sh），本补丁不是崩溃原因，
# 但三处都是真实缺陷，保留。
set -e
cd "$(dirname "$0")"
python3 - <<'PYEOF'
import io, sys
p = "dospad/dosbox/src/hardware/mixer.cpp"
src = io.open(p, encoding="utf-8").read()
if "idos-fix" in src:
    print("mixer.cpp 已修过，跳过"); sys.exit(0)

# ── ① + ② AddChannel：加锁 + 清零 done/needed ────────────────────────
a = ("MixerChannel * MIXER_AddChannel(MIXER_Handler handler,Bitu freq,const char * name) {\n"
     "\tMixerChannel * chan=new MixerChannel();\n")
assert a in src, "找不到 MIXER_AddChannel 锚点"
b = ("MixerChannel * MIXER_AddChannel(MIXER_Handler handler,Bitu freq,const char * name) {\n"
     "\tMixerChannel * chan=new MixerChannel(); /* idos-fix */\n"
     "\t/* idos-fix: done/needed were left uninitialised, so MIXER_CallBack's\n"
     "\t * \"chan->done > reduce\" test read garbage on a freshly added channel. */\n"
     "\tchan->done=0;\n"
     "\tchan->needed=0;\n")
src = src.replace(a, b, 1)

a = ("\tmixer.channels = chan;\n"
     "\treturn chan;\n"
     "}\n")
assert a in src, "找不到 MIXER_AddChannel 链表插入锚点"
b = ("\t/* idos-fix: MIXER_CallBack walks mixer.channels on the SDL audio thread;\n"
     "\t * publishing the new head without the audio lock races with it. */\n"
     "\tSDL_LockAudio();\n"
     "\tmixer.channels = chan;\n"
     "\tSDL_UnlockAudio();\n"
     "\treturn chan;\n"
     "}\n")
src = src.replace(a, b, 1)

# ── ① DelChannel：整段摘除操作放进锁里 ───────────────────────────────
a = ("void MIXER_DelChannel(MixerChannel* delchan) {\n"
     "\tMixerChannel * chan=mixer.channels;\n"
     "\tMixerChannel * * where=&mixer.channels;\n"
     "\twhile (chan) {\n"
     "\t\tif (chan==delchan) {\n"
     "\t\t\t*where=chan->next;\n"
     "\t\t\tdelete delchan;\n"
     "\t\t\treturn;\n"
     "\t\t}\n"
     "\t\twhere=&chan->next;\n"
     "\t\tchan=chan->next;\n"
     "\t}\n"
     "}\n")
assert a in src, "找不到 MIXER_DelChannel 锚点"
b = ("void MIXER_DelChannel(MixerChannel* delchan) {\n"
     "\t/* idos-fix: unlink and free under the audio lock -- MIXER_CallBack may be\n"
     "\t * walking this list on the audio thread right now. */\n"
     "\tSDL_LockAudio();\n"
     "\tMixerChannel * chan=mixer.channels;\n"
     "\tMixerChannel * * where=&mixer.channels;\n"
     "\twhile (chan) {\n"
     "\t\tif (chan==delchan) {\n"
     "\t\t\t*where=chan->next;\n"
     "\t\t\tdelete delchan;\n"
     "\t\t\tSDL_UnlockAudio();\n"
     "\t\t\treturn;\n"
     "\t\t}\n"
     "\t\twhere=&chan->next;\n"
     "\t\tchan=chan->next;\n"
     "\t}\n"
     "\tSDL_UnlockAudio();\n"
     "}\n")
src = src.replace(a, b, 1)

# ── ③ overflow 分支的无符号下溢 ──────────────────────────────────────
a = ("\t\tif (mixer.done > MIXER_BUFSIZE)\n"
     "\t\t\tindex_add = MIXER_BUFSIZE - 2*mixer.min_needed;\n"
     "\t\telse\n"
     "\t\t\tindex_add = mixer.done - 2*mixer.min_needed;\n"
     "\t\tindex_add = (index_add << INDEX_SHIFT_LOCAL) / need;\n"
     "\t\treduce = mixer.done - 2* mixer.min_needed;\n")
assert a in src, "找不到 overflow 分支锚点"
b = ("\t\t/* idos-fix: Bitu is unsigned. This branch only guarantees\n"
     "\t\t * mixer.done >= mixer.max_needed, and max_needed can be smaller than\n"
     "\t\t * 2*min_needed, so these subtractions could wrap to a ~2^64 value and\n"
     "\t\t * blow up both index_add and reduce. Clamp at zero. */\n"
     "\t\tBitu headroom = (mixer.done > MIXER_BUFSIZE) ? MIXER_BUFSIZE : mixer.done;\n"
     "\t\tindex_add = (headroom > 2*mixer.min_needed) ? headroom - 2*mixer.min_needed : 0;\n"
     "\t\tindex_add = (index_add << INDEX_SHIFT_LOCAL) / need;\n"
     "\t\treduce = (mixer.done > 2*mixer.min_needed) ? mixer.done - 2*mixer.min_needed : 0;\n")
src = src.replace(a, b, 1)

io.open(p, "w", encoding="utf-8").write(src)
print("mixer.cpp 修复完成（加锁 + done/needed 清零 + 下溢钳制）")
PYEOF
echo "✅ 完成。回到 Xcode ⌘R 重新运行。"
