# 英雄无敌2 · iOS 整合包（重建版）

把 iDOS/dospad 改造成一个「点开图标就是英雄无敌2」的原生感 iOS app。

原套件在 `~/Downloads/Heroes_of_Might_and_Magic_II_Gold_China/Disc 1/整合IPA构建套件/`，
连同整棵改过的源码树一起被删了（废纸篓已空、无 Time Machine、`Disc 1.rar` 里只有光盘镜像）。
这份是 2026-08-08 重建的：`dospad/` 重新从上游克隆，所有改动按会话记录逐条复现成下面的脚本。

## 用法

```bash
bash branding/make_icon.sh   # 从你自己那份游戏里生成图标（见下）
bash fix_gfx.sh        # 崩溃修复（必须）
bash fix_cdaudio.sh    # CD 音频缓冲区（健壮性）
bash fix_mixer.sh      # 混音器加锁 / 下溢（健壮性）
bash fix_payload.sh    # 内置游戏数据 + 首次启动释放
bash fix_branding.sh   # 应用名 / 图标 / 启动图 / 方向 / bundle id
bash fix_touch.sh      # 原生触摸
```

全部幂等，可重复跑。跑完在 Xcode 里打开 `dospad/dospad.xcodeproj` 选 iDOS scheme 即可。

游戏数据包 `英雄无敌2.idos` 放在套件根目录（1.7GB，**不入库**，本地是指向
`~/Downloads/Heroes_of_Might_and_Magic_II_Gold_China/英雄无敌2.idos` 的软链接）。

### 仓库里为什么没有游戏素材

`dospad/` 是 [litchie/dospad](https://github.com/litchie/dospad) 的 vendored 副本，
GPL-2.0，许可证见 `dospad/LICENSE`。第一个提交是 `2e329c6` 原始上游、未作改动，
**第二个提交就是本项目的全部改动** —— `git show HEAD` 即完整补丁集。

游戏本体和从游戏里提取的美术资源都不入库：

- `英雄无敌2.idos`（1.7GB 游戏数据）
- `branding/icon-1024.png`（从 `HEROES2W.EXE` 的 PE 资源段里挖出来的官方盾牌图标）
- `dospad/Resources/Assets.xcassets/LaunchLogo.imageset/`

图标用 `branding/make_icon.sh` 从你自己那份游戏里重新生成，**字节级可复现**
（SHA256 与原图一致）。仓库里 `AppIcon.appiconset/*.png` 保留的是上游的占位图标；
跑完 `fix_branding.sh` 后它们在本地会显示为已修改 —— 这是预期的，别提交。

## 各脚本改了什么

| 脚本 | 内容 | 源码标记 |
|---|---|---|
| `fix_gfx.sh` | ①脏行遍历加上界 ②脏矩形裁到 surface ③旋转期间渲染门控 | `idos-gfx-fix` / `idos-render-gate` |
| `fix_cdaudio.sh` | `CDAudioCallBack` 请求长度钳制 | `idos-cd-fix` |
| `fix_mixer.sh` | 声道链表加 `SDL_LockAudio`；`done/needed` 清零；overflow 分支无符号下溢钳制 | `idos-fix` |
| `fix_payload.sh` | 加 `Copy Game Payload` 构建阶段；`DPAppDelegate` 首次启动把 GamePayload 复制到 Documents；摘掉 `Embed App Extensions` | `GamePayload` |
| `fix_branding.sh` | 名字「英雄无敌2」、官方盾牌图标 13 尺寸、启动图、横屏优先、bundle id `com.litchie.hmm2cn` | — |
| `fix_touch.sh` | `Mouse_CursorSet` 补移动计数；点击等光标就位；Direct touch 默认开 | `idos-direct-touch` / `idos-click-settle` |

## 崩溃是怎么定位的（结论，别再走一遍弯路）

真凶是 **`GFX_EndUpdate` 的脏行遍历失控**，跟音频毫无关系。

`RENDER_StartUpdate` 每帧把脏行表重置成一个 `0`，而旧循环只判 `y < sdl.draw.height`，
高度为 0 的表项让 `y` 永不前进 → 死循环：越界读 `Scaler_ChangedLines`，同时把 8 字节
`SDL_Rect` 一路写穿 `updateRects`，扫过后面所有全局变量。`mixer` 恰好排在 `sdl` 后面
390336 字节处，`mixer.channels` 被写成 `SDL_Rect{x=460,y=0,w=640,h=0}`，读成指针就是
`0x280000001cc` —— 于是音频线程野指针崩溃，且每次地址完全相同，把人误导到音频方向。

ASan 一发命中（`global-buffer-overflow in GFX_EndUpdate`，紧邻 `Scaler_ChangedLines` 尾部）。
**调内存破坏用 `-enableAddressSanitizer YES` 比 lldb watchpoint 高效得多。**

修①之后横屏走 GL 路径又暴露出②矩形越界；修②之后旋转仍必崩，探针显示连跑 1129 帧没事
然后突然崩 —— 是竞争：UIKit 在主线程重建 CAEAGLLayer/GL 纹理时，模拟线程正在
`GFX_EndUpdate` 里画，SDL 1.2 compat 层两边毫无同步。于是有了③渲染门控。

## 原生触摸是怎么做的

iDOS 本来就有 `Direct touch`（`mouse_abs_enable`），一路接到了 DOSBox 的 `Mouse_CursorSet`，
但**默认关着，而且对英雄无敌2 完全无效**。

实测（在 `INT33_Handler` 上打点统计）：英雄无敌2 的 INT 33h 调用里 **`0Bh`(读取移动计数)
占 36/40，从不调 `03h`(读取位置)**，开局还用 `02h` 把驱动光标藏掉自己画。也就是说它
纯靠相对位移自己积分出光标位置 —— 原来的 `Mouse_CursorSet` 只设 `mouse.x/y`，它根本不看。

所以 `fix_touch.sh` 做两件事：

**1. `Mouse_CursorSet` 把绝对定位翻译成等效移动计数**

换算口径：**mickey 增量 = 屏幕像素增量，且不乘 `mickeysPerPixel`**。

这个系数是真机标定出来的，不是推的：把游戏光标归零到第 0 行作为已知原点，手指点第
371 行，截图量到光标停在第 309 行 —— `309/371 = 0.833 = 1/1.2`，正好是驱动虚拟高度
200 与屏幕 480 之比。也就是说游戏把 mickey 直接当屏幕行数用，不走驱动那套 200 行空间。

**别按 `max_x/max_y`（驱动虚拟范围）算。** 真机上 `max=(639,199)` 而 `mode=640x480`：
横向 639 和 640 恰好重合怎么算都对，纵向却差 2.4 倍。当初就是栽在这儿 —— 纵向每次少走
1/1.2，越积越偏，最后同一个按钮怎么点都点不中（在同一点重复点击时增量为 0，光标纹丝
不动，所以永远修不回来）。**"只有纵向不准"这个不对称本身就是线索。**

**2. 点击等光标就位**

轻点是"先挪光标、再按下"，两件事只隔几十毫秒；游戏按自己的帧率轮询 `0Bh`，按键先到
就会把这一下点在**上一个**位置上 —— 表现为光标明明停在按钮上、点下去毫无反应。

用 `set`/`read` 握手：`Mouse_CursorSet` 里 `set++`，游戏调 `0Bh`/`03h` 时 `read` 追平
`set`；iOS 侧等到"位移已处理且已被读走"再按下，上限 300ms 兜底。帧率快时通常 8~16ms
就放行，**比固定延时还跟手**。早先用固定 100ms，够不够取决于当时帧率，慢一帧就漏，
真机上表现为"时灵时不灵"。

### 试过并已回退的方案（别再走一遍）

| 方案 | 结果 |
|---|---|
| mickey 增量按屏幕像素但乘了 `mickeysPerPixel_y`(=2) | 2 倍超调，比不改还糟，连原本能点中的按钮也点飞 |
| 每次点击前把光标顶到角落归零（对抗漂移） | 大地图上 HoMM2 把"光标停在屏幕边缘"当成自动滚动，每点一下地图就猛滚一次（"画面飞了"）。系数标定对之后本来也不会漂 |

### 右键按住（两指）

HoMM2 靠**按住右键**看信息面板（英雄、部队、城镇、资源），松开才关。上游 iDOS 的三种
右键全是瞬时 click（两指点一下、双击、外接鼠标），面板一闪而过甚至根本不出来。

现在：**第二根手指按下 = 右键按下，抬起 = 右键抬起**。

- 定位由**第一根手指**决定 —— 手指1 指着要看的东西，手指2 只当右键
- 单指长按 1.5 秒仍是**左键**按住（拆分部队要用），没动它
- 快速两指点一下仍然得到一次右键 click，属于严格扩展

两个坑（都在 `fix_touch.sh` 里修了）：

1. **右键会卡住**。上游代码在主手指抬起时会把 `_secondaryTouch` 一起清空，此后第二根
   手指抬起就匹配不上，右键永远按着 —— 游戏会一直卡在信息面板里。所以主手指抬起、
   以及系统打断触摸（`touchesCancelled`）时，都必须先强制抬起右键。
2. **会误发左键点击**。右键按住期间主手指抬起，原逻辑会走 `addClick:NO` 补一次左键。

另外右键按下同样要走 set/read 握手 —— 否则右键按在上一个位置，面板显示的是错的东西。

### 关于光标本身

**藏不掉。** 106 次点击的日志全是 `hidden=1` —— 驱动光标一直是隐藏的，你看到的那个剑形
指针是**游戏自己画进画面里的**，和城堡、树一样属于画面内容。要去掉只能改 `HEROES2.AGG`
里的光标 ICN 资源，代价是丢失形状提示（剑=攻击、马靴=移动、船=上船）。直接触摸修好后
光标本来就在手指底下，基本被盖住。

### 验证

- 模拟器（iPad）：注入真实 CGEvent，竖屏点中「新游戏」→「标准游戏」，横屏点中「原始地图」
- 真机（iPhone 17 Pro Max）：竖屏对局设置页各按钮、横屏大地图英雄/城堡图标均正常

**模拟器验证覆盖不到这个问题** —— 菜单界面的驱动范围恰好是 640×480，纵向系数错了也看不
出来。真机上换个界面（驱动范围变成 640×200）才暴露。

想退回旧的"推鼠标"模式：设置 → 英雄无敌2 → 关掉 Direct touch。
注意 `registerDefaults` 只对没手动设过这个开关的安装生效，覆盖安装到以前存过旧值的设备
上不会自动变，得手动开一次。

## 构建目标的坑

- **iOS 模拟器**：必须加 `ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO VALID_ARCHS=x86_64`。
  `deps/lib/*.a` 是 fat 库但 arm64 切片是真机 iOS 平台，只有 x86_64 切片是 IOSSIMULATOR。
  x86_64 应用在 Apple Silicon 模拟器上靠 Rosetta 正常跑（含 ASan）。
- **My Mac (Designed for iPad)**：命令行跑不起来（`open` 报 incorrect executable format），
  只能在 Xcode GUI 里选 My Mac ⌘R。
- **真机**：`xcrun devicectl` 可装可跑（`--console` 能收 stdout/stderr），但**设备必须解锁且亮屏**，
  否则被 `FBSOpenApplicationErrorDomain error 7 (Locked)` 拒绝。
- app 约 1.7GB，每次 install 要等几分钟。
