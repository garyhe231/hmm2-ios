#!/bin/bash
# 原生触摸：点哪儿就点哪儿，而不是"屏幕上一个鼠标 + 滑动推着它走"。
#
# iDOS 本来就有这个能力（Settings 里的 "Direct touch" / mouse_abs_enable），
# 一路接到了 DOSBox：SDL_uikitview 在 abs 模式下走 sendMouseCoordinate →
# SDL_SendMouseMotion(relative=0) → sdlmain.cpp 的 HandleMouseMotion 里那段
# #ifdef IPHONEOS 分支 → Mouse_CursorSet(归一化坐标)。只是默认关着。
#
# 默认值来自 Settings.bundle/Root.plist 的 DefaultValue（DPSettings
# registerDefaultSettings 把它们喂给 registerDefaults），所以改这里就是改默认。
# 开关本身保留在"设置 → 英雄无敌2"里，想退回旧的推鼠标模式随时可关。
set -e
cd "$(dirname "$0")"

echo "==> 1/3 Mouse_CursorSet：把绝对定位翻译成移动计数"
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

b = """void Mouse_CursorSet(float x,float y)
{
    float nx, ny;
    if (CurMode->type == M_TEXT) {
        nx = x*CurMode->swidth;
        ny = y*CurMode->sheight * 8 / CurMode->cheight;
    } else {
        nx = x*mouse.max_x;
        ny = y*mouse.max_y;
    }
    /* 和 Mouse_CursorMoved 用同一套边界，越界的手指位置钳进屏幕内 */
    if (nx > mouse.max_x) nx = mouse.max_x;
    if (nx < mouse.min_x) nx = mouse.min_x;
    if (ny > mouse.max_y) ny = mouse.max_y;
    if (ny < mouse.min_y) ny = mouse.min_y;

    /* idos-direct-touch: 只设 mouse.x/y 对很多游戏是无效的。实测英雄无敌2
     * 的 INT 33h 调用里 0Bh(读取移动计数) 占 36/40，从不调 03h(读取位置)，
     * 而且开局就用 02h 把驱动光标藏掉自己画 —— 也就是说它完全靠相对位移
     * 自己积分出光标位置。所以绝对定位必须翻译成等效的移动计数喂给它。
     * 换算口径同 Mouse_CursorMoved：mickey 增量 = 像素增量 * mickeysPerPixel。
     * 默认 8 mickey/像素是 DOS 鼠标驱动的标准值，游戏侧按同样口径还原，
     * 所以是 1:1；手指移到边缘时两边都会被钳到同一组边界，天然重新对齐。 */
    float dx = nx - mouse.x;
    float dy = ny - mouse.y;
    mouse.mickey_x += dx * mouse.mickeysPerPixel_x;
    mouse.mickey_y += dy * mouse.mickeysPerPixel_y;
    if (mouse.mickey_x >= 32768.0) mouse.mickey_x -= 65536.0;
    else if (mouse.mickey_x <= -32769.0) mouse.mickey_x += 65536.0;
    if (mouse.mickey_y >= 32768.0) mouse.mickey_y -= 65536.0;
    else if (mouse.mickey_y <= -32769.0) mouse.mickey_y += 65536.0;

    mouse.x = nx;
    mouse.y = ny;
    Mouse_AddEvent(MOUSE_HAS_MOVED);
	DrawCursor();
}"""
s = s.replace(a, b, 1)
io.open(p, "w", encoding="utf-8").write(s)
print("   mouse.cpp 已改")
PYEOF

echo "==> 2/3 点击等光标就位（否则点在旧位置上）"
python3 - <<'PYEOF'
import io, sys
p = "dospad/SDL/src/video/uikit/SDL_uikitview.m"
s = io.open(p, encoding="utf-8").read()
if "idos-click-settle" in s:
    print("   已修过，跳过"); sys.exit(0)

# 1) 记录最后一次发送坐标的时刻
a = """	int _pendingClickIndex;
	int _pendingClickCount;
}"""
assert a in s, "找不到 ivar 块"
b = """	int _pendingClickIndex;
	int _pendingClickCount;
	/* idos-click-settle: 最后一次把绝对坐标交给 DOS 的时刻 */
	CFAbsoluteTime _lastCoordSent;
}"""
s = s.replace(a, b, 1)

a = """    if(SDL_GetMouse(0)->relative_mode == SDL_TRUE)
        SDL_SetRelativeMouseMode(0, SDL_FALSE);
    SDL_SendMouseMotion(index, 0, x, y, 0);  // note 2nd argument 'relative'=0"""
assert a in s, "找不到 sendMouseCoordinate 主体"
b = """    if(SDL_GetMouse(0)->relative_mode == SDL_TRUE)
        SDL_SetRelativeMouseMode(0, SDL_FALSE);
    SDL_SendMouseMotion(index, 0, x, y, 0);  // note 2nd argument 'relative'=0
    _lastCoordSent = CFAbsoluteTimeGetCurrent();   /* idos-click-settle */"""
s = s.replace(a, b, 1)

# 2) 直接触摸模式下，按键要等游戏把这次移动读进去再发
a = """	_pendingClickCount++;
	[NSThread cancelPreviousPerformRequestsWithTarget:self
		selector:@selector(sendPendingClicks)
		object:nil];
	[self sendPendingClicks];
}"""
assert a in s, "找不到 addClick 尾部"
b = """	_pendingClickCount++;
	[NSThread cancelPreviousPerformRequestsWithTarget:self
		selector:@selector(sendPendingClicks)
		object:nil];

	/* idos-click-settle: 轻点是"先把光标挪过去，再按下"，但这两件事只隔几十
	 * 毫秒。游戏是按自己的节奏轮询 INT 33h 0Bh 取移动量的（英雄无敌2 就是这
	 * 么干的），按键先到、位移还没被读走，游戏就会把这一下点在**上一个**光标
	 * 位置上 —— 实测光标明明停在"新游戏"上，点下去却毫无反应。
	 * 所以绝对定位模式下把按下推迟到位移发出后至少 CLICK_SETTLE 秒。
	 * 相对模式不受影响（那种模式下光标本来就是跟着手指连续走的）。 */
	NSTimeInterval wait = 0;
	if ([DPSettings shared].mouseAbsEnable) {
		const NSTimeInterval CLICK_SETTLE = 0.10;
		wait = CLICK_SETTLE - (CFAbsoluteTimeGetCurrent() - _lastCoordSent);
		if (wait < 0) wait = 0;
	}
	if (wait > 0)
		[self performSelector:@selector(sendPendingClicks) withObject:nil afterDelay:wait];
	else
		[self sendPendingClicks];
}"""
s = s.replace(a, b, 1)
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
    # idos-native-touch: 直接触摸默认开
    if item.get("Key") == "mouse_abs_enable" and item.get("DefaultValue") is not True:
        item["DefaultValue"] = True
        changed.append("mouse_abs_enable -> true")

if changed:
    with open(p, "wb") as f:
        plistlib.dump(d, f)
    for c in changed:
        print("   " + c)
else:
    print("   已经是目标值，跳过")
PYEOF

echo '✅ 完成。注意：registerDefaults 只对没手动设过这个开关的安装生效，'
echo '   模拟器/真机上如果之前存过旧值，先删掉 app 再装。'
