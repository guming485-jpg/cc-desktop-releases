#!/bin/bash
#
# 理财人CC 一键安装/更新脚本
#
# 用法:
#   bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/guming485-jpg/cc-desktop-releases/main/install.sh)
#
# 行为:
#   1. 从 GitHub API 拉取最新版本号和 DMG 下载地址
#   2. 通过国内镜像下载 DMG (gh-proxy.com → ghfast.top → 直连)
#   3. 退出已运行的理财人CC
#   4. 替换 /Applications/理财人CC.app
#   5. 清除 macOS quarantine 标记 (绕过 Gatekeeper)
#   6. 启动新版本

set -e

APP_NAME="理财人CC"
APP_PATH="/Applications/${APP_NAME}.app"
REPO="guming485-jpg/cc-desktop-releases"

echo "─────────────────────────────────────"
echo "  理财人CC 自动安装/更新"
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
echo "🔍 查询最新版本..."
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
API_RESP=$(curl -fsSL --connect-timeout 10 "$API_URL" 2>/dev/null || true)

if [ -z "$API_RESP" ]; then
    echo "❌ 无法访问 GitHub API,请检查网络"
    exit 1
fi

TAG=$(echo "$API_RESP" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
DMG_URL=$(echo "$API_RESP" | grep '"browser_download_url"' | grep -E "${ARCH_TAG}\.dmg" | head -1 | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')

if [ -z "$DMG_URL" ]; then
    # 如果没有架构后缀的 DMG,fallback 到任意 dmg
    DMG_URL=$(echo "$API_RESP" | grep '"browser_download_url"' | grep '\.dmg' | head -1 | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')
fi

if [ -z "$TAG" ] || [ -z "$DMG_URL" ]; then
    echo "❌ 解析版本信息失败"
    exit 1
fi

echo "✨ 最新版本: $TAG"
echo "🔗 DMG URL: $DMG_URL"

# ── 3. 镜像 fallback 下载 ──
TMP_DMG=$(mktemp -t cc-install-XXXXXX.dmg)
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
if pgrep -f "${APP_NAME}.app/Contents/MacOS" > /dev/null; then
    echo
    echo "🛑 退出当前运行的 ${APP_NAME}..."
    osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
    for i in $(seq 1 15); do
        if ! pgrep -f "${APP_NAME}.app/Contents/MacOS" > /dev/null; then break; fi
        sleep 1
    done
    pkill -9 -f "${APP_NAME}.app/Contents/MacOS" 2>/dev/null || true
    sleep 1
fi

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

# ── 7. 替换到 /Applications ──
echo
echo "📦 安装到 ${APP_PATH}..."
STAGING="/Applications/.cc-staging-$$.app"
cp -R "$SRC" "$STAGING"
xattr -dr com.apple.quarantine "$STAGING" 2>/dev/null || true
rm -rf "$APP_PATH"
mv "$STAGING" "$APP_PATH"

# ── 8. 卸载 DMG ──
hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true

# ── 9. 再次清除 quarantine (双保险) ──
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

# ── 10. 启动 ──
echo
echo "🚀 启动 ${APP_NAME}..."
open "$APP_PATH"

echo
echo "─────────────────────────────────────"
echo "  ✅ 安装完成! 版本: $TAG"
echo "─────────────────────────────────────"
