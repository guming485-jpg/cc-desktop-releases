#!/bin/bash
#
# Alphox 一键安装/更新脚本
#
# 推荐用法（兼容性最好）:
#   curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/guming485-jpg/cc-desktop-releases/main/install.sh | bash
#
# 备用用法（部分系统可能显示"已损坏"）:
#   bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/guming485-jpg/cc-desktop-releases/main/install.sh)
#
# 行为:
#   1. 从 GitHub 最新 Release 页面解析同一版本的 DMG 下载地址
#   2. 通过国内镜像下载 DMG (gh-proxy.com → ghfast.top → 直连)
#   3. 退出已运行的 Alphox 或理财人CC
#   4. 替换 /Applications/Alphox.app，并移除旧名称应用
#   5. 清除 macOS quarantine 标记 (绕过 Gatekeeper)
#   6. 刷新 Launch Services 缓存 (修复问号图标)
#   7. 启动新版本

set -e

APP_NAME="Alphox"
LEGACY_APP_NAME="理财人CC"
APP_PATH="/Applications/${APP_NAME}.app"
LEGACY_APP_PATH="/Applications/${LEGACY_APP_NAME}.app"
REPO="guming485-jpg/cc-desktop-releases"

echo "─────────────────────────────────────"
echo "  Alphox 自动安装/更新"
echo "─────────────────────────────────────"
echo

# ── 1. 检测架构 ──
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    ARCH_TAG="arm64"
elif [ "$ARCH" = "x86_64" ]; then
    ARCH_TAG="x64"
else
    echo "❌ 不支持的架构: $ARCH"
    exit 1
fi
echo "📦 当前架构: $ARCH_TAG"

# ── 2. 拉取最新 release 信息 ──
# 说明：解析只用 grep/sed（macOS 自带），绝不依赖 python3/jq——干净 macOS 不预装这些，
# 一旦依赖外部运行时，新用户机器会卡在解析步骤报"解析版本信息失败"。
echo "🔍 查询最新版本..."
# 不再依赖 GitHub API：公共代理共享 API 限额，耗尽后会让所有用户同时失败。
# latest 页面只负责给出 tag，expanded_assets 只在该 tag 内选包，避免从历史 Release 误捞旧 DMG。
LATEST_ORIGINAL="https://github.com/${REPO}/releases/latest"
LATEST_MIRRORS=(
    "https://gh-proxy.com/${LATEST_ORIGINAL}"
    "https://ghfast.top/${LATEST_ORIGINAL}"
    "${LATEST_ORIGINAL}"
)

TAG=""
for LATEST_URL in "${LATEST_MIRRORS[@]}"; do
    echo "   尝试: $LATEST_URL"
    LATEST_RESP=$(curl -fsSL --connect-timeout 10 --max-time 30 "$LATEST_URL" 2>/dev/null || true)
    TAG=$(printf '%s\n' "$LATEST_RESP" \
        | grep -m1 -Eo "/${REPO}/releases/tag/[^\"<]+" \
        | sed -E 's#^.*/releases/tag/##' || true)
    if printf '%s\n' "$TAG" | grep -Eq '^v?[0-9]+(\.[0-9]+){2}([._-][[:alnum:]]+)*$'; then
        echo "   ✅ 成功"
        break
    fi
    TAG=""
done

if [ -z "$TAG" ]; then
    echo "❌ 无法查询 GitHub 最新 Release（所有镜像均失败）,请检查网络"
    exit 1
fi

ASSETS_ORIGINAL="https://github.com/${REPO}/releases/expanded_assets/${TAG}"
ASSETS_MIRRORS=(
    "https://gh-proxy.com/${ASSETS_ORIGINAL}"
    "https://ghfast.top/${ASSETS_ORIGINAL}"
    "${ASSETS_ORIGINAL}"
)

DMG_REF=""
for ASSETS_URL in "${ASSETS_MIRRORS[@]}"; do
    echo "   尝试制品列表: $ASSETS_URL"
    ASSETS_RESP=$(curl -fsSL --connect-timeout 10 --max-time 30 "$ASSETS_URL" 2>/dev/null || true)
    DMG_REF=$(printf '%s\n' "$ASSETS_RESP" \
        | grep -Eo 'href="[^"]+/releases/download/[^"]+\.dmg"' \
        | sed -E 's/^href="([^"]+)"$/\1/' \
        | grep -F "/download/${TAG}/" \
        | grep -E -- "-${ARCH_TAG}([._-][[:alnum:]]+)*\.dmg$" \
        | head -1 || true)
    if [ -n "$DMG_REF" ]; then
        echo "   ✅ 找到当前版本制品"
        break
    fi
done

case "$DMG_REF" in
    http://*|https://*) DMG_URL="$DMG_REF" ;;
    /*) DMG_URL="https://github.com${DMG_REF}" ;;
    *) DMG_URL="" ;;
esac

if [ -z "$TAG" ] || [ -z "$DMG_URL" ]; then
    echo "❌ ${TAG} 没有匹配当前架构 ${ARCH_TAG} 的 DMG，已停止；不会降级安装历史版本"
    exit 1
fi

echo "✨ 最新版本: $TAG"
echo "🔗 DMG URL: $DMG_URL"

# ── 3. 镜像 fallback 下载 ──
TMP_DMG=$(mktemp -t alphox-install-XXXXXX.dmg)
trap "rm -f '$TMP_DMG'" EXIT

MIRRORS=(
    "https://gh-proxy.com/${DMG_URL}"
    "https://ghfast.top/${DMG_URL}"
    "${DMG_URL}"
)

DOWNLOADED=0
for M in "${MIRRORS[@]}"; do
    echo
    echo "📥 尝试从 $M 下载..."
    if curl -fL --connect-timeout 10 --speed-time 15 --speed-limit 50000 \
            --progress-bar -o "$TMP_DMG" "$M"; then
        SIZE=$(stat -f%z "$TMP_DMG" 2>/dev/null || stat -c%s "$TMP_DMG" 2>/dev/null || echo 0)
        if [ "$SIZE" -gt 10000000 ]; then  # > 10MB 才算下载成功
            echo "✅ 下载完成 ($(echo "scale=1; $SIZE/1024/1024" | bc) MB)"
            DOWNLOADED=1
            break
        else
            echo "⚠️  文件太小 ($SIZE bytes),尝试下个镜像"
        fi
    else
        echo "⚠️  下载失败,尝试下个镜像"
    fi
done

if [ $DOWNLOADED -eq 0 ]; then
    echo "❌ 所有镜像都失败,请稍后重试"
    exit 1
fi

# ── 4. 退出旧版本 ──
for RUNNING_APP in "$APP_NAME" "$LEGACY_APP_NAME"; do
    if pgrep -f "${RUNNING_APP}.app/Contents/MacOS" > /dev/null; then
        echo
        echo "🛑 退出当前运行的 ${RUNNING_APP}..."
        osascript -e "quit app \"${RUNNING_APP}\"" 2>/dev/null || true
        for i in $(seq 1 15); do
            if ! pgrep -f "${RUNNING_APP}.app/Contents/MacOS" > /dev/null; then break; fi
            sleep 1
        done
        pkill -9 -f "${RUNNING_APP}.app/Contents/MacOS" 2>/dev/null || true
        sleep 1
    fi
done

# ── 5. 挂载 DMG ──
echo
echo "📀 挂载 DMG..."
MOUNT_OUT=$(hdiutil attach "$TMP_DMG" -nobrowse -noverify -noautoopen -mountrandom /tmp)
MOUNT_POINT=$(echo "$MOUNT_OUT" | grep -E "/tmp/dmg\." | tail -1 | awk '{for(i=3;i<=NF;i++) printf "%s ",$i; print ""}' | sed 's/ *$//')
if [ -z "$MOUNT_POINT" ]; then
    MOUNT_POINT=$(echo "$MOUNT_OUT" | grep "/Volumes/" | tail -1 | awk '{for(i=3;i<=NF;i++) printf "%s ",$i; print ""}' | sed 's/ *$//')
fi
if [ -z "$MOUNT_POINT" ]; then
    echo "❌ 挂载失败"
    exit 1
fi
echo "✅ 挂载于: $MOUNT_POINT"

# ── 6. 找源 .app ──
SRC="$MOUNT_POINT/${APP_NAME}.app"
if [ ! -d "$SRC" ]; then
    SRC=$(ls -d "$MOUNT_POINT"/*.app 2>/dev/null | head -1)
fi
if [ ! -d "$SRC" ]; then
    echo "❌ 在 DMG 中找不到 .app"
    hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
    exit 1
fi

# ── 7. 替换到 /Applications (原子操作) ──
echo
echo "📦 安装到 ${APP_PATH}..."
STAGING="/Applications/.alphox-staging-$$.app"
cp -R "$SRC" "$STAGING"

# 清除隔离标记 (避免 Gatekeeper 警告)
xattr -dr com.apple.quarantine "$STAGING" 2>/dev/null || true

# 原子替换；仅清理这两个明确的同产品安装路径，避免新旧名称并存。
rm -rf "$APP_PATH"
if [ -d "$LEGACY_APP_PATH" ]; then
    echo "🧹 清理旧名称应用: ${LEGACY_APP_PATH}"
    rm -rf "$LEGACY_APP_PATH"
fi
mv "$STAGING" "$APP_PATH"

# ── 8. 卸载 DMG ──
hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true

# ── 9. 再次清除 quarantine (双保险) ──
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

# ── 10. 刷新 Launch Services 缓存 (修复问号图标) ──
echo
echo "🔄 刷新系统缓存..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH" 2>/dev/null || true

# 注意：不要 killall Dock —— Dock 同时渲染桌面壁纸，重启 Dock 在与 open 竞态下
# 可能导致桌面变黑无法恢复。lsregister -f 已足够刷新图标，启动后系统会再次注册。

# ── 11. 启动 ──
echo
echo "🚀 启动 ${APP_NAME}..."
open "$APP_PATH"

echo
echo "─────────────────────────────────────"
echo "  ✅ 安装完成! 版本: $TAG"
echo "─────────────────────────────────────"
echo
echo "💡 提示: 如果图标显示问号,请稍等几秒或重新登录让系统刷新"
