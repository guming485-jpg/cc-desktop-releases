# 理财人CC 发布通道

桌面应用的 DMG 二进制和 release notes 都在 [Releases](https://github.com/guming485-jpg/cc-desktop-releases/releases) 页面。

## 一键安装/更新最新版

复制粘贴到终端即可:

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/guming485-jpg/cc-desktop-releases/main/install.sh)
```

脚本会自动:
1. 查询最新版本
2. 通过国内镜像加速下载 DMG (gh-proxy.com → ghfast.top → 直连)
3. 退出已运行的旧版本
4. 替换到 /Applications
5. 清除 macOS Gatekeeper 标记
6. 启动新版本

整个过程通常 1-2 分钟完成,无需手动拖拽。

## 在应用内更新

也可以直接打开应用 → 设置 → 检测更新,走应用内的图形化更新流程。
