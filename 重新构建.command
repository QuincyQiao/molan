#!/bin/zsh
# 编译「墨览」，自测通过后装到 /Applications、注册快速查看扩展并打开。
# 只想打包不安装：MOLAN_STAGE_ONLY=1 ./重新构建.command（产物在 .build/墨览.app）
# 在桌面放一个替身：MOLAN_DESKTOP_ALIAS=1；装完不自动打开：MOLAN_NO_OPEN=1
set -euo pipefail
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy ALL_PROXY all_proxy
project_dir="${0:A:h}"
build_dir="$project_dir/.build"
web_dir="$project_dir/web"
staged_app="$build_dir/墨览.app"
appex="$staged_app/Contents/PlugIns/MolanPreview.appex"
installed_app="/Applications/墨览.app"
target="arm64-apple-macosx14.0"
mkdir -p "$build_dir"

print -r -- "正在打包页面……"
[[ -d "$web_dir/node_modules" ]] || npm ci --prefix "$web_dir" --no-fund --no-audit
node "$web_dir/build.mjs"
node "$web_dir/test/run.mjs"

print -r -- "正在编译主程序和预览扩展……"
/usr/bin/xcrun swiftc -O -swift-version 5 -target "$target" -module-name Molan \
    -framework AppKit -framework SwiftUI -framework WebKit -framework UniformTypeIdentifiers \
    "$project_dir"/Sources/App/*.swift "$project_dir"/Sources/Shared/*.swift -o "$build_dir/Molan"
/usr/bin/xcrun swiftc -O -swift-version 5 -target "$target" -module-name MolanPreview -parse-as-library -application-extension \
    -framework AppKit -framework QuickLookUI -framework WebKit -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    "$project_dir"/Sources/Preview/*.swift "$project_dir"/Sources/Shared/*.swift -o "$build_dir/MolanPreview"
"$build_dir/Molan" --self-test --res "$web_dir/dist"

print -r -- "正在组装……"
rm -rf "$staged_app" "$build_dir/Molan.iconset"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$appex/Contents/MacOS" "$appex/Contents/Resources" "$build_dir/Molan.iconset"
cp "$build_dir/Molan" "$staged_app/Contents/MacOS/Molan"
cp "$project_dir/Support/App-Info.plist" "$staged_app/Contents/Info.plist"
cp "$build_dir/MolanPreview" "$appex/Contents/MacOS/MolanPreview"
cp "$project_dir/Support/Preview-Info.plist" "$appex/Contents/Info.plist"
cp -R "$web_dir/dist" "$appex/Contents/Resources/web"

"$build_dir/Molan" --make-icon "$build_dir/icon-1024.png"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$build_dir/icon-1024.png" --out "$build_dir/Molan.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$(( size * 2 ))
    /usr/bin/sips -z "$doubled" "$doubled" "$build_dir/icon-1024.png" --out "$build_dir/Molan.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$build_dir/Molan.iconset" -o "$staged_app/Contents/Resources/Molan.icns"
/usr/bin/plutil -lint "$staged_app/Contents/Info.plist" "$appex/Contents/Info.plist" >/dev/null

# 临时签名；认人规则固定成包名，重编以后系统还认得是同一个程序
/usr/bin/codesign --force --sign - --timestamp=none --entitlements "$project_dir/Support/Preview.entitlements" \
    --requirements '=designated => identifier "local.molan.preview"' "$appex"
/usr/bin/codesign --force --sign - --timestamp=none --requirements '=designated => identifier "local.molan"' "$staged_app"
/usr/bin/codesign --verify --strict --deep "$staged_app"

if [[ -n "${MOLAN_STAGE_ONLY:-}${SOFTWARE_SYNC_STAGE_ONLY:-}" ]]; then
    print -r -- "已打包：$staged_app"
    exit 0
fi

print -r -- "正在安装……"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
/usr/bin/osascript -e 'tell application id "local.molan" to quit' >/dev/null 2>&1 || true
/usr/bin/pkill -x MolanPreview >/dev/null 2>&1 || true
rm -rf "$installed_app"
/usr/bin/ditto "$staged_app" "$installed_app"
"$lsregister" -f -R "$installed_app"
/usr/bin/pluginkit -a "$installed_app/Contents/PlugIns/MolanPreview.appex"
/usr/bin/qlmanage -r >/dev/null 2>&1 || true
/usr/bin/qlmanage -r cache >/dev/null 2>&1 || true

# 放替身不放软链接：桌面可能在 iCloud 里，替身记的是书签，应用重装也认得
desktop_alias="$HOME/Desktop/墨览"
if [[ -n "${MOLAN_DESKTOP_ALIAS:-}" && ! -e "$desktop_alias" ]]; then
    /usr/bin/osascript -l JavaScript -e "
ObjC.import('Foundation');
const target = \$.NSURL.fileURLWithPath('$installed_app');
const data = target.bookmarkDataWithOptionsIncludingResourceValuesForKeysRelativeToURLError(1 << 10, \$(), \$(), \$());
\$.NSURL.writeBookmarkDataToURLOptionsError(data, \$.NSURL.fileURLWithPath('$desktop_alias'), 1 << 10, \$());
" >/dev/null
fi

[[ -n "${MOLAN_NO_OPEN:-}" ]] || /usr/bin/open "$installed_app"
print -r -- "已装好：$installed_app"
