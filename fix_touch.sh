#!/bin/bash
# 原生触摸：点哪儿就点哪儿，而不是"屏幕上一个鼠标 + 滑动推着它走"。
#
# iDOS 本来就有这个能力（Settings 里的 "Direct touch" / mouse_abs_enable），
# 一路接到了 DOSBox：SDL_uikitview 在 abs 模式下走 sendMouseCoordinate →
# SDL_SendMouseMotion(relative=0) → sdlmain.cpp HandleMouseMotion 里那段
# #ifdef IPHONEOS 分支 → Mouse_CursorSet(归一化坐标)。但默认关着，而且
# 对英雄无敌2 这类游戏**根本不起作用** —— 见下面第 1 段。
#
# 三处改动，全部经真机验证：
#   1) Mouse_CursorSet 把绝对定位翻译成移动计数（含真机标定的换算系数）
#   2) 点击等游戏读走位移再按下（set/read 握手，不是固定延时）
#   3) Direct touch 默认打开
set -e
cd "$(dirname "$0")"

echo "==> 1/3 Mouse_CursorSet：绝对定位 → 移动计数"
python3 - <<'PYEOF'
import io, sys
p = "dospad/dosbox/src/ints/mouse.cpp"
s = io.open(p, encoding="utf-8").read()
if "idos-direct-touch" in s:
    print("   已修过，跳过"); sys.exit(0)

a = """void Mouse_CursorSet(float x,float y)
{
    if (CurMode->type == M_TEXT) {
        mouse.x = x*CurMode->swidth;
        mouse.y = y*CurMode->sheight * 8 / CurMode->cheight;
    } else {
        mouse.x = x*mouse.max_x;
        mouse.y = y*mouse.max_y;
    }
    Mouse_AddEvent(MOUSE_HAS_MOVED);
	DrawCursor();
}"""
assert a in s, "找不到 Mouse_CursorSet 锚点"

b = """/* idos-click-sync: 让 iOS 侧能判断"这次位移游戏是否已经读走了"。
 * 轻点的语义是"先把光标挪到手指下，再按下"，但两件事只隔几十毫秒，而游戏是按
 * 自己的帧率轮询 INT 33h 取移动量的。按键赶在位移前面，游戏就会把这一下点在
 * 上一个位置 —— 真机上表现为"时灵时不灵"。
 * 原先用固定 100ms 延时兜，但帧率一慢就不够。改成握手：
 *   set  在 Mouse_CursorSet 里自增（DOSBox 事件线程真正处理到这次位移时）
 *   read 在游戏调 0Bh/03h 取位移或位置时追平 set
 * iOS 侧等到 set 超过发送时的值且 read == set 再按下，等不到就用上限兜底。 */
volatile unsigned idos_motion_set = 0;
volatile unsigned idos_motion_read = 0;
extern "C" unsigned iDOS_MotionSetCount(void)  { return idos_motion_set; }
extern "C" unsigned iDOS_MotionReadCount(void) { return idos_motion_read; }

void Mouse_CursorSet(float x,float y)
{
    float nx, ny;
    if (CurMode->type == M_TEXT) {
        nx = x*CurMode->swidth;
        ny = y*CurMode->sheight * 8 / CurMode->cheight;
    } else {
        nx = x*mouse.max_x;
        ny = y*mouse.max_y;
    }
    /* 和 Mouse_CursorMoved 用同一套边界，越界的手指位置钳进屏幕内。
     * 手指划到边缘时驱动和游戏会被钳到同一处，这是唯一的天然重同步点。 */
    if (nx > mouse.max_x) nx = mouse.max_x;
    if (nx < mouse.min_x) nx = mouse.min_x;
    if (ny > mouse.max_y) ny = mouse.max_y;
    if (ny < mouse.min_y) ny = mouse.min_y;

    /* idos-direct-touch: 只设 mouse.x/y 对很多游戏是无效的。真机实测英雄无敌2
     * 的 INT 33h 调用里 0Bh(读取移动计数) 占 36/40，从不调 03h(读取位置)，
     * 开局还用 02h 把驱动光标藏掉自己画 —— 它完全靠相对位移自己积分出光标
     * 位置。所以绝对定位必须翻译成等效的移动计数喂给它。
     *
     * 换算口径：mickey 增量 = **屏幕像素**增量，且**不乘** mickeysPerPixel。
     * 这是标定出来的，不是推的：把游戏光标先归零到第 0 行作为已知原点，再让
     * 手指点在第 371 行，截图量到光标停在第 309 行 ——
     * 309/371 = 0.833 = 1/1.2，正好是驱动虚拟高度 200 与屏幕 480 之比。
     * 也就是说游戏把 mickey 直接当屏幕行数用，不走驱动那套 200 行空间。
     *
     * 横向怎么算都对，因为 max_x=639 和屏幕宽 640 本来就重合 —— 这正是当初
     * "只有纵向点不准"的原因，那个不对称本身就是线索。
     * 踩过的两个坑：按 max_y 算 → 纵向只有该走距离的 1/1.2，偏上；
     * 按屏幕像素但乘了 mickeysPerPixel_y(=2) → 2 倍超调，更糟。 */
    float sw = (float)CurMode->swidth;
    float sh = (float)CurMode->sheight;
    float prev_sx = (mouse.max_x > 0) ? mouse.x * (sw - 1) / mouse.max_x : mouse.x;
    float prev_sy = (mouse.max_y > 0) ? mouse.y * (sh - 1) / mouse.max_y : mouse.y;
    mouse.mickey_x += x * (sw - 1) - prev_sx;
    mouse.mickey_y += y * (sh - 1) - prev_sy;
    if (mouse.mickey_x >= 32768.0) mouse.mickey_x -= 65536.0;
    else if (mouse.mickey_x <= -32769.0) mouse.mickey_x += 65536.0;
    if (mouse.mickey_y >= 32768.0) mouse.mickey_y -= 65536.0;
    else if (mouse.mickey_y <= -32769.0) mouse.mickey_y += 65536.0;

    mouse.x = nx;
    mouse.y = ny;
    idos_motion_set++;   /* idos-click-sync */
    Mouse_AddEvent(MOUSE_HAS_MOVED);
	DrawCursor();
}"""
s = s.replace(a, b, 1)

# 游戏取走位移/位置时让 read 追平 set
for anchor in ("\tcase 0x0b:\t/* Read Motion Data */\n"
               "\t\treg_cx=static_cast<Bit16s>(mouse.mickey_x);\n"
               "\t\treg_dx=static_cast<Bit16s>(mouse.mickey_y);\n"
               "\t\tmouse.mickey_x=0;\n"
               "\t\tmouse.mickey_y=0;\n",
               "\tcase 0x03:\t/* Return position and Button Status */\n"
               "\t\treg_bx=mouse.buttons;\n"
               "\t\treg_cx=POS_X;\n"
               "\t\treg_dx=POS_Y;\n"):
    assert anchor in s, "找不到 INT33 锚点"
    s = s.replace(anchor, anchor +
                  "#ifdef IPHONEOS\n"
                  "\t\tidos_motion_read = idos_motion_set;   /* idos-click-sync */\n"
                  "#endif\n", 1)

io.open(p, "w", encoding="utf-8").write(s)
print("   mouse.cpp 已改")
PYEOF

echo "==> 2/3 点击等光标就位（握手，不是固定延时）"
python3 - <<'PYEOF'
import io, sys
p = "dospad/SDL/src/video/uikit/SDL_uikitview.m"
s = io.open(p, encoding="utf-8").read()
if "idos-click-settle" in s:
    print("   已修过，跳过"); sys.exit(0)

a = '#define MAX_PENDING_CLICKS 10\n'
assert a in s, "找不到常量锚点"
s = s.replace(a, a +
    '/* idos-click-settle: 等游戏读走位移的轮询间隔与上限 */\n'
    '#define CLICK_SETTLE_POLL 0.008f\n'
    '#define CLICK_SETTLE_MAX  0.30f\n'
    'extern unsigned iDOS_MotionSetCount(void);\n'
    'extern unsigned iDOS_MotionReadCount(void);\n', 1)

a = """	int _pendingClickIndex;
	int _pendingClickCount;
}"""
assert a in s, "找不到 ivar 块"
s = s.replace(a, """	int _pendingClickIndex;
	int _pendingClickCount;
	/* idos-click-settle: 发送坐标时的 set 计数，用来判断这次位移是否已被处理 */
	unsigned _motionSetAtSend;
	CFAbsoluteTime _clickWaitStart;
}""", 1)

a = "    SDL_SendMouseMotion(index, 0, x, y, 0);  // note 2nd argument 'relative'=0"
assert a in s, "找不到 sendMouseCoordinate 主体"
s = s.replace(a, a + "\n    _motionSetAtSend = iDOS_MotionSetCount();   /* idos-click-settle */", 1)

a = """	_pendingClickCount++;
	[NSThread cancelPreviousPerformRequestsWithTarget:self
		selector:@selector(sendPendingClicks)
		object:nil];
	[self sendPendingClicks];
}"""
assert a in s, "找不到 addClick 尾部"
s = s.replace(a, """	_pendingClickCount++;
	[NSThread cancelPreviousPerformRequestsWithTarget:self
		selector:@selector(sendPendingClicks)
		object:nil];

	/* idos-click-settle: 轻点是"先把光标挪过去，再按下"，但这两件事只隔几十
	 * 毫秒。游戏按自己的帧率轮询 INT 33h 0Bh 取移动量（英雄无敌2 就是这么
	 * 干的），按键先到、位移还没被读走，这一下就点在**上一个**位置上 ——
	 * 表现为光标明明停在按钮上，点下去毫无反应。
	 * 固定 100ms 延时兜不住（够不够取决于当时帧率，慢一帧就漏），改成握手：
	 * 等 DOSBox 真正处理了这次位移(set 变化)且游戏已读走(read 追平 set)。
	 * 帧率快时通常 8~16ms 就放行，比固定延时还跟手。 */
	if (![DPSettings shared].mouseAbsEnable) {
		[self sendPendingClicks];
		return;
	}
	_clickWaitStart = CFAbsoluteTimeGetCurrent();
	[self waitMotionThenClick];
}

- (void)waitMotionThenClick
{
	unsigned setNow = iDOS_MotionSetCount();
	BOOL processed = (setNow != _motionSetAtSend);
	BOOL consumed  = processed && (iDOS_MotionReadCount() == setNow);
	NSTimeInterval waited = CFAbsoluteTimeGetCurrent() - _clickWaitStart;

	if (consumed || waited >= CLICK_SETTLE_MAX) {
		[self sendPendingClicks];
		return;
	}
	[self performSelector:@selector(waitMotionThenClick)
			   withObject:nil afterDelay:CLICK_SETTLE_POLL];
}""", 1)
io.open(p, "w", encoding="utf-8").write(s)
print("   SDL_uikitview.m 已改")
PYEOF

echo "==> 3/3 Direct touch 默认打开"
PLIST="dospad/Resources/Settings.bundle/Root.plist"
[ -f "$PLIST" ] || { echo "错误：找不到 $PLIST"; exit 1; }
python3 - "$PLIST" <<'PYEOF'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f:
    d = plistlib.load(f)
changed = []
for item in d.get("PreferenceSpecifiers", []):
    if item.get("Key") == "mouse_abs_enable" and item.get("DefaultValue") is not True:
        item["DefaultValue"] = True
        changed.append("mouse_abs_enable -> true")
if changed:
    with open(p, "wb") as f:
        plistlib.dump(d, f)
    for c in changed: print("   " + c)
else:
    print("   已经是目标值，跳过")
PYEOF

echo ''
echo '✅ 完成。'
echo '注意：registerDefaults 只对没手动设过这个开关的安装生效。覆盖安装到一台'
echo '      以前存过旧值的设备上不会自动变 —— 去 设置 → 英雄无敌2 手动打开一次。'
echo ''
echo '试过但**不要**再加的东西：'
echo '  · 每次点击前把光标顶到角落归零 —— 大地图上 HoMM2 把"光标在屏幕边缘"'
echo '    当成自动滚动地图，于是每点一下地图就猛滚一次（"画面飞了"）。'
echo '    系数标定对之后本来也不需要它了。'
