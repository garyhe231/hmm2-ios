#!/bin/bash
# 把 iDOS 改造成「英雄无敌2」的外观：应用名、图标、启动图、方向偏好。
# 幂等，可重复运行；dospad/ 被重新克隆后跑一遍即可恢复。
#
# ── 图标来源 ──────────────────────────────────────────────────────────
# branding/icon-1024.png 是游戏自带的官方图标（盾牌+立狮纹章），从
# HEROES2W.EXE 的 PE 资源里挖出来的。原始只有 32x32/16色，sips 解 4bpp
# 调色板会解错（颜色全泛白），所以是自己解码 + 纯 Python 写 PNG，
# 32 倍最近邻放大到 1024（整数倍 → 像素边缘锐利），配深蓝渐变底。
# 复现过程见 branding/{peico,exico,icodec,mkicon}.py
#
# ── 方向 ──────────────────────────────────────────────────────────────
# 横屏排在方向数组最前面。iDOS 的横屏场景本来就是全屏的（screen 节点铺满
# 画布 + 自动收起的 landbar），竖屏场景才是那套复古电脑外壳（背景图 +
# 虚拟键盘 + 光驱/软驱按钮）。所以横屏 = 原生游戏观感，竖屏 = 需要键盘时
# 转过去用。注意 ~ipad 变体在 iPad 上优先生效，漏改就没效果。
# DPEmulatorViewController.supportedInterfaceOrientations 上游就是 MaskAll，
# 无需改动。
set -e
cd "$(dirname "$0")"

NAME="英雄无敌2"
PLIST="dospad/Resources/iDOS-Info.plist"
PBX="dospad/dospad.xcodeproj/project.pbxproj"
ICONSET="dospad/Resources/Assets.xcassets/AppIcon.appiconset"
LAUNCHSET="dospad/Resources/Assets.xcassets/LaunchLogo.imageset"
MASTER="branding/icon-1024.png"

[ -f "$MASTER" ] || { echo "错误：找不到 $MASTER"; exit 1; }
[ -f "$PLIST" ]  || { echo "错误：找不到 $PLIST（先跑 build_ipa.sh 拉取源码）"; exit 1; }

echo "==> 1/4 应用名 → $NAME"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $NAME" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $NAME" "$PLIST"
# pbxproj 里的 INFOPLIST_KEY_CFBundleDisplayName 是第二个来源，一并改掉避免打架
python3 - "$PBX" "$NAME" <<'PYEOF'
import io, re, sys
p, name = sys.argv[1], sys.argv[2]
s = io.open(p, encoding="utf-8").read()
new, n = re.subn(r'INFOPLIST_KEY_CFBundleDisplayName = "[^"]*";',
                 f'INFOPLIST_KEY_CFBundleDisplayName = "{name}";', s)
if n: io.open(p, "w", encoding="utf-8").write(new)
print(f"   pbxproj 改了 {n} 处")
PYEOF

echo "==> 1b/4 Bundle ID → com.litchie.hmm2cn"
# 换掉 app target 的 bundle id，免得和真的 iDOS 撞车（装了两个会互相覆盖）。
# 只改 com.litchie.idos3 本身，com.litchie.idos3.thumbnail 那个扩展 target 不动
# （它已经被 fix_payload.sh 从 Embed 阶段摘掉了，改不改都无所谓）。
python3 - "$PBX" <<'PYEOF'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
new, n = re.subn(r'PRODUCT_BUNDLE_IDENTIFIER = com\.litchie\.idos3;',
                 'PRODUCT_BUNDLE_IDENTIFIER = com.litchie.hmm2cn;', s)
if n: io.open(p, "w", encoding="utf-8").write(new)
print(f"   pbxproj 改了 {n} 处")
PYEOF

echo "==> 2/4 方向：横屏优先，保留竖屏（键盘只在竖屏场景里）"
for K in "UISupportedInterfaceOrientations" "UISupportedInterfaceOrientations~ipad"; do
  /usr/libexec/PlistBuddy -c "Delete :$K" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$K array" "$PLIST"
  for O in LandscapeLeft LandscapeRight Portrait PortraitUpsideDown; do
    /usr/libexec/PlistBuddy -c "Add :$K: string UIInterfaceOrientation$O" "$PLIST"
  done
done

echo "==> 3/4 应用图标（13 个尺寸，无 alpha）"
cp "$MASTER" "$ICONSET/iTunesArtwork@2x.png"
for s in 20 29 40 58 60 76 80 87 120 152 167 180; do
  cp "$MASTER" "$ICONSET/icon-$s.png"
  sips -z $s $s "$ICONSET/icon-$s.png" >/dev/null 2>&1
done

echo "==> 4/4 启动图（与图标同一张，点图标→启动图→游戏 视觉连续）"
mkdir -p "$LAUNCHSET"
cp "$MASTER" "$LAUNCHSET/launchlogo.png"
cat > "$LAUNCHSET/Contents.json" <<'EOF'
{
  "images" : [
    {
      "filename" : "launchlogo.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF
# LaunchScreen.storyboard：纯黑底 + 居中 logo（1:1 比例，占高度 32%）
python3 - "dospad/Resources/LaunchScreen.storyboard" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
if "hm2-lg-001" in s:
    print("   storyboard 已改过，跳过"); sys.exit(0)
old = ('                        <color key="backgroundColor" red="0.0" green="0.0" '
       'blue="0.0" alpha="1" colorSpace="calibratedRGB"/>\n')
assert old in s, "找不到 LaunchScreen 背景色锚点"
new = ('                        <subviews>\n'
       '                            <imageView clipsSubviews="YES" userInteractionEnabled="NO" '
       'contentMode="scaleAspectFit" horizontalHuggingPriority="251" verticalHuggingPriority="251" '
       'image="LaunchLogo" translatesAutoresizingMaskIntoConstraints="NO" id="hm2-lg-001">\n'
       '                                <rect key="frame" x="103.5" y="249.5" width="168" height="168"/>\n'
       '                            </imageView>\n'
       '                        </subviews>\n'
       + old +
       '                        <constraints>\n'
       '                            <constraint firstItem="hm2-lg-001" firstAttribute="centerX" '
       'secondItem="r0g-d7-3IO" secondAttribute="centerX" id="hm2-ct-001"/>\n'
       '                            <constraint firstItem="hm2-lg-001" firstAttribute="centerY" '
       'secondItem="r0g-d7-3IO" secondAttribute="centerY" id="hm2-ct-002"/>\n'
       '                            <constraint firstItem="hm2-lg-001" firstAttribute="height" '
       'secondItem="r0g-d7-3IO" secondAttribute="height" multiplier="0.32" id="hm2-ct-003"/>\n'
       '                            <constraint firstItem="hm2-lg-001" firstAttribute="width" '
       'secondItem="hm2-lg-001" secondAttribute="height" multiplier="1:1" id="hm2-ct-004"/>\n'
       '                        </constraints>\n')
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
print("   storyboard 已加入居中 logo")
PYEOF

echo ""
echo "✅ 完成。核对："
/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :UISupportedInterfaceOrientations~ipad" "$PLIST"
echo "回到 Xcode ⌘R 重新运行（改图标后建议先 Clean Build Folder）。"
