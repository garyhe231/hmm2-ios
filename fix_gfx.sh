#!/bin/bash
# 修复 GFX_EndUpdate 里的三个缺陷（真正的崩溃元凶，与音频无关）。
#
# ── 缺陷① 脏行遍历失控 ────────────────────────────────────────────────
# RENDER_StartUpdate 每帧重置 Scaler_ChangedLines[0]=0、Scaler_ChangedLineIndex=0，
# 所以"整帧无变化"时交给 GFX_EndUpdate 的脏行表只有一个 0。旧循环只判
# y < sdl.draw.height，高度为 0 的表项让 y 永不前进 → 死循环：一边越界读
# Scaler_ChangedLines(1024 项)，一边把 8 字节 SDL_Rect 一路往后写穿
# updateRects[1024]，扫过后面所有全局变量。mixer 正好排在 sdl 后面 390336
# 字节处，mixer.channels 被写成 SDL_Rect{x=460,y=0,w=640,h=0}，读成指针就是
# 0x280000001cc → 音频线程 MIXER_CallBack 野指针崩溃，且每次地址完全相同。
# (ASan 实测: global-buffer-overflow in GFX_EndUpdate，紧邻 Scaler_ChangedLines 尾部)
#
# ── 缺陷② 脏矩形超出 surface ──────────────────────────────────────────
# clip.y + y + h 会超过 surface 高度，而 SDL 1.2 的 GLES 渲染器不做裁剪，
# SDL_UpdateRects 就读出纹理边界 → glDrawArrays 里 EXC_BAD_ACCESS。
# 崩溃栈: glDrawArrays_IMM_Exec ← GLES_RenderCopy ← SDL_RenderCopy
#         ← SDL_UpdateRects ← GFX_EndUpdate ← RENDER_EndUpdate
# DOSBox 作者早就怀疑过这里 —— 原代码就留着一段 #if 0 注掉的检查:
#     if (rect->h + rect->y > sdl.surface->h) LOG_MSG("WTF ...")
# 修①之后②才会暴露出来（横屏走 GL 路径时）。两个都得修。
#
# ── 缺陷③ 渲染线程与 UIKit 抢 GL ────────────────────────────────────
# 修①②之后仍会崩，探针实测：surface 640x480、矩形全部在界内、连跑 1129 帧
# 没事，然后突然崩 —— 所以不是算术越界，是竞争。旋转/布局变化时 UIKit 在主
# 线程重建 CAEAGLLayer 与 GL 纹理，而 DOSBox 模拟线程同时在 GFX_EndUpdate 里
# 往里画；SDL 1.2 compat 层的 SDL_UpdateRects 操作模块级全局
# SDL_VideoSurface/SDL_VideoTexture，两边毫无同步。修复前单次旋转必崩(2/2)，
# 加门控后 10 次往返旋转全过。
#
# 修法：遍历受"有效表项数 + 两个数组容量"三重约束，必然收敛；每个矩形裁到
# surface 边界内，退化矩形直接丢弃不交给 SDL；转场期间由 VC 抬起渲染门控，
# 模拟线程跳过这几帧。
# 附带给 ScalerAddLines 的下标加上界，避免超高输出把脏行表写出界。
set -e
cd "$(dirname "$0")"
python3 - <<'PYEOF'
import io, re, sys

# ── 1) sdlmain.cpp ────────────────────────────────────────────────────
p = "dospad/dosbox/src/gui/sdlmain.cpp"
src = io.open(p, encoding="utf-8").read()
if "idos-gfx-fix" in src:
    print("sdlmain.cpp 已修过，跳过")
else:
    # 1a) 给遍历加上界。锚点带上 rectCount 声明，避免命中 1448 行那个
    #     桌面 OpenGL 分支（iOS 不走那条，且它没有 rectCount）。
    m = re.search(
        r'([ \t]*)Bitu y = 0, index = 0, rectCount = 0;\n'
        r'[ \t]*while \(y < sdl\.draw\.height\) \{\n', src)
    assert m, "找不到 GFX_EndUpdate 脏行遍历锚点"
    I = m.group(1)
    new = (
        f"{I}Bitu y = 0, index = 0, rectCount = 0;\n"
        f"{I}/* idos-gfx-fix: changedLines holds only Scaler_ChangedLineIndex valid\n"
        f"{I} * entries, and their heights need not add up to sdl.draw.height -- a\n"
        f"{I} * frame with no changed lines arrives as a single 0. The old loop tested\n"
        f"{I} * y < sdl.draw.height alone, so a 0-height entry left y stuck and the\n"
        f"{I} * walk ran away: reading past Scaler_ChangedLines and writing 8-byte\n"
        f"{I} * SDL_Rects past updateRects over whatever globals followed. It reached\n"
        f"{I} * mixer.channels and crashed the audio thread with a fixed bad address.\n"
        f"{I} * Bound the walk by the valid entry count and both array capacities. */\n"
        f"{I}const Bitu maxRects = sizeof(sdl.updateRects) / sizeof(sdl.updateRects[0]);\n"
        f"{I}while (y < sdl.draw.height && index <= Scaler_ChangedLineIndex &&\n"
        f"{I}       index < SCALER_MAXHEIGHT && rectCount < maxRects) {{\n"
    )
    src = src[:m.start()] + new + src[m.end():]

    # 1b) 矩形裁剪。整块替换 SDL_Rect 赋值 + 那段 #if 0 检查。
    m2 = re.search(
        r'([ \t]*)SDL_Rect \*rect = &sdl\.updateRects\[rectCount\+\+\];\n'
        r'(?:.*?\n)*?'
        r'[ \t]*#endif\n',
        src)
    assert m2, "找不到 SDL_Rect 赋值块锚点"
    J = m2.group(1)
    clip = (
        f"{J}/* idos-gfx-fix: clip the dirty rect to the surface. Upstream already\n"
        f"{J} * suspected this -- the original code carried an #if 0'd check logging\n"
        f'{J} * "WTF h + y > surface->h" right here. clip.y + y + h really can run\n'
        f"{J} * past the surface, and SDL 1.2's GLES renderer does no clipping of its\n"
        f"{J} * own, so SDL_UpdateRects walks off the texture and faults inside\n"
        f"{J} * glDrawArrays. Drop degenerate rects instead of handing SDL one. */\n"
        f"{J}int rx = sdl.clip.x;\n"
        f"{J}int ry = sdl.clip.y + (int)y;\n"
        f"{J}int rw = (int)sdl.draw.width;\n"
        f"{J}int rh = (int)changedLines[index];\n"
        f"{J}if (rx < 0) {{ rw += rx; rx = 0; }}\n"
        f"{J}if (ry < 0) {{ rh += ry; ry = 0; }}\n"
        f"{J}if (rx + rw > sdl.surface->w) rw = sdl.surface->w - rx;\n"
        f"{J}if (ry + rh > sdl.surface->h) rh = sdl.surface->h - ry;\n"
        f"{J}if (rw > 0 && rh > 0) {{\n"
        f"{J}\tSDL_Rect *rect = &sdl.updateRects[rectCount++];\n"
        f"{J}\trect->x = (Bit16s)rx;\n"
        f"{J}\trect->y = (Bit16s)ry;\n"
        f"{J}\trect->w = (Bit16u)rw;\n"
        f"{J}\trect->h = (Bit16u)rh;\n"
        f"{J}}}\n"
    )
    src = src[:m2.start()] + clip + src[m2.end():]
    io.open(p, "w", encoding="utf-8").write(src)
    print("sdlmain.cpp 修复完成（遍历上界 + 矩形裁剪）")

# ── 2) render_scalers.cpp ─────────────────────────────────────────────
p = "dospad/dosbox/src/gui/render_scalers.cpp"
src = io.open(p, encoding="utf-8").read()
if "idos-gfx-fix" in src:
    print("render_scalers.cpp 已修过，跳过")
else:
    a = ("\tif ((Scaler_ChangedLineIndex & 1) == changed ) {\n"
         "\t\tScaler_ChangedLines[Scaler_ChangedLineIndex] += count;\n")
    assert a in src, "找不到 ScalerAddLines 锚点"
    b = ("\t/* idos-gfx-fix: the index had no upper bound, so a tall enough output could\n"
         "\t * walk Scaler_ChangedLines off its end. When the list is full, fold the run\n"
         "\t * into the last entry instead of advancing past the array. */\n"
         "\tif ((Scaler_ChangedLineIndex & 1) == changed ||\n"
         "\t    Scaler_ChangedLineIndex + 1 >= SCALER_MAXHEIGHT) {\n"
         "\t\tScaler_ChangedLines[Scaler_ChangedLineIndex] += count;\n")
    src = src.replace(a, b, 1)
    io.open(p, "w", encoding="utf-8").write(src)
    print("render_scalers.cpp 修复完成")

# ── 3) 渲染门控：sdlmain.cpp 侧 ───────────────────────────────────────
p = "dospad/dosbox/src/gui/sdlmain.cpp"
src = io.open(p, encoding="utf-8").read()
if "idos-render-gate" in src:
    print("渲染门控(sdlmain)已加过，跳过")
else:
    a = "static SDL_Block sdl;\n"
    assert a in src, "找不到 SDL_Block 锚点"
    src = src.replace(a, a + """
/* idos-render-gate: UIKit rebuilds the CAEAGLLayer / GL texture on the main thread
 * during an orientation change, while the DOSBox emulation thread is inside
 * GFX_StartUpdate/GFX_EndUpdate drawing into it. Nothing in SDL 1.2's compat layer
 * synchronises the two -- SDL_UpdateRects operates on the module-global
 * SDL_VideoSurface/SDL_VideoTexture -- so a rotation reliably faulted inside
 * glDrawArrays. The view controller raises this gate for the duration of the
 * transition and the render thread simply skips those frames. */
volatile int idos_render_suspend = 0;
extern "C" void iDOS_SuspendRender(int on) { idos_render_suspend = on ? 1 : 0; }
""", 1)
    b = "bool GFX_StartUpdate(Bit8u * & pixels,Bitu & pitch) {\n\tif (!sdl.active || sdl.updating)\n\t\treturn false;\n"
    assert b in src, "找不到 GFX_StartUpdate 锚点"
    src = src.replace(b, b + "\tif (idos_render_suspend)   /* idos-render-gate */\n\t\treturn false;\n", 1)
    c = "void GFX_EndUpdate( const Bit16u *changedLines ) {\n#if C_DDRAW\n\tint ret;\n#endif\n"
    assert c in src, "找不到 GFX_EndUpdate 锚点"
    src = src.replace(c, c + "\tif (idos_render_suspend) {   /* idos-render-gate */\n\t\tsdl.updating = false;\n\t\treturn;\n\t}\n", 1)
    io.open(p, "w", encoding="utf-8").write(src)
    print("渲染门控(sdlmain) 已加入")

# ── 4) 渲染门控：ViewController 侧 ────────────────────────────────────
p = "dospad/dospad/Main/DPEmulatorViewController.m"
src = io.open(p, encoding="utf-8").read()
if "iDOS_SuspendRender" in src:
    print("渲染门控(VC)已加过，跳过")
else:
    a = "- (UIInterfaceOrientationMask)supportedInterfaceOrientations\n"
    assert a in src, "找不到 supportedInterfaceOrientations 锚点"
    gate = """/* idos-render-gate: hold off the emulation thread's drawing for the whole
 * rotation transition. UIKit reallocates the GL layer/texture on the main thread
 * here; SDL 1.2's compat layer shares SDL_VideoSurface/SDL_VideoTexture with the
 * render thread without any locking, so drawing across the transition faulted
 * inside glDrawArrays (SDL_UpdateRects -> GLES_RenderCopy). */
extern void iDOS_SuspendRender(int on);

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
\tiDOS_SuspendRender(1);
\t[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
\t[coordinator animateAlongsideTransition:nil
\t\tcompletion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
\t\t\t// let the new geometry settle a frame before drawing resumes
\t\t\tdispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
\t\t\t               dispatch_get_main_queue(), ^{
\t\t\t\tiDOS_SuspendRender(0);
\t\t\t});
\t\t}];
}

"""
    io.open(p, "w", encoding="utf-8").write(src.replace(a, gate + a, 1))
    print("渲染门控(VC) 已加入")
PYEOF
echo "✅ 完成。回到 Xcode ⌘R 重新运行。"
