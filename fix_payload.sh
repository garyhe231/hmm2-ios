#!/bin/bash
# 把《英雄无敌II 黄金版》做成 app 的内置内容：
#
# ① Xcode 里加一个 "Copy Game Payload" Run Script 阶段，编译后把
#    英雄无敌2.idos 整包 rsync 进 .app/GamePayload（约 1.7GB）。
#    放在 Resources/Sources/Frameworks 之后、签名之前，所以真机构建时
#    这些文件会一并被签名，不需要事后补签。
# ② DPAppDelegate 首次启动时把 GamePayload 复制到 Documents，再启动 DOS。
#    iDOS 的工作目录是 Documents，游戏得可写（存档、配置），所以不能直接
#    从只读的 bundle 里跑。已存在 HEROES2 就跳过，不会覆盖存档。
#
# 幂等，可重复运行。
set -e
cd "$(dirname "$0")"

GAME="$PWD/英雄无敌2.idos"
[ -d "$GAME" ] || { echo "错误：找不到 $GAME（需在套件根目录放上游戏包或其软链接）"; exit 1; }

echo "==> 1/2 DPAppDelegate：首次启动释放内置游戏"
python3 - <<'PYEOF'
import io, sys
p = "dospad/dospad/Main/DPAppDelegate.m"
src = io.open(p, encoding="utf-8").read()
if "GamePayload" in src:
    print("   补丁已存在，跳过")
    sys.exit(0)

method = '''
// === 整合包补丁：首次启动把内置游戏复制到 Documents，然后再启动 DOS ===
- (void)installBundledGameThenStart
{
\tdispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
\t\tNSFileManager *fm = [NSFileManager defaultManager];
\t\tNSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
\t\tNSString *payload = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"GamePayload"];
\t\tif (![fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"HEROES2"]] && [fm fileExistsAtPath:payload]) {
\t\t\tfor (NSString *item in [fm contentsOfDirectoryAtPath:payload error:nil]) {
\t\t\t\tNSString *dst = [docs stringByAppendingPathComponent:item];
\t\t\t\tif (![fm fileExistsAtPath:dst]) {
\t\t\t\t\t[fm copyItemAtPath:[payload stringByAppendingPathComponent:item] toPath:dst error:nil];
\t\t\t\t}
\t\t\t}
\t\t}
\t\tdispatch_async(dispatch_get_main_queue(), ^{
\t\t\t[self performSelector:@selector(startDOS) withObject:nil afterDelay:1];
\t\t});
\t});
}

'''
old_call = "[self performSelector:@selector(startDOS) withObject:nil afterDelay:1];"
assert old_call in src, "找不到 startDOS 调用点"
src = src.replace(old_call, "[self installBundledGameThenStart];", 1)

anchor = "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:"
assert anchor in src, "找不到插入点 didFinishLaunchingWithOptions"
src = src.replace(anchor, method + anchor, 1)

io.open(p, "w", encoding="utf-8").write(src)
print("   补丁完成")
PYEOF

echo "==> 2/2 Xcode 加入 Copy Game Payload 构建阶段"
python3 - <<'PYEOF'
import io, sys
p = "dospad/dospad.xcodeproj/project.pbxproj"
s = io.open(p, encoding="utf-8").read()
if "Copy Game Payload" in s:
    print("   构建阶段已存在，跳过"); sys.exit(0)

PHASE_ID = "AA110011AA110011AA110011"

# a) 阶段定义，插在 PBXShellScriptBuildPhase 段末尾
end = "/* End PBXShellScriptBuildPhase section */"
assert end in s, "找不到 PBXShellScriptBuildPhase 段"
block = (
    f"\t\t{PHASE_ID} /* Copy Game Payload */ = {{\n"
    "\t\t\tisa = PBXShellScriptBuildPhase;\n"
    "\t\t\tbuildActionMask = 2147483647;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t);\n"
    "\t\t\tinputPaths = (\n"
    "\t\t\t);\n"
    '\t\t\tname = "Copy Game Payload";\n'
    "\t\t\toutputPaths = (\n"
    "\t\t\t);\n"
    "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
    "\t\t\tshellPath = /bin/sh;\n"
    '\t\t\tshellScript = "GAME=\\"$SRCROOT/../英雄无敌2.idos\\"\\nif [ ! -d \\"$GAME\\" ]; then echo \\"warning: game package not found: $GAME\\"; exit 0; fi\\nmkdir -p \\"$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME/GamePayload\\"\\nrsync -a --delete \\"$GAME/\\" \\"$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME/GamePayload/\\"\\n";\n'
    "\t\t};\n"
)
s = s.replace(end, block + end, 1)

# b) 挂到 iDOS target 的 buildPhases 末尾（在签名之前跑，所以真机构建会连同
#    GamePayload 一起签名）。同时摘掉 Embed App Extensions —— iDOSThumbnail
#    缩略图扩展要自己一套描述文件，对这个只跑一个游戏的 app 没用，去掉省事。
#    上次能跑的工程就是这个配置。
anchor = ("\t\t\t\tE7BE1304128BF31A0046990B /* Frameworks */,\n"
          "\t\t\t\tE79610A1256A6B5700556B9D /* Embed App Extensions */,\n"
          "\t\t\t);\n")
assert anchor in s, "找不到 iDOS target 的 buildPhases"
s = s.replace(anchor,
              "\t\t\t\tE7BE1304128BF31A0046990B /* Frameworks */,\n"
              f"\t\t\t\t{PHASE_ID} /* Copy Game Payload */,\n"
              "\t\t\t);\n", 1)

io.open(p, "w", encoding="utf-8").write(s)
print("   构建阶段已加入")
PYEOF

echo ""
echo "✅ 完成。游戏包：$GAME"
