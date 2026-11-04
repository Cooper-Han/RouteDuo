# RouteDuo

macOS 菜单栏双网络分流工具：配置的地址走分流网络，其他流量走默认网络。

支持 Apple Silicon（arm64），最低系统版本以发布包为准。首次运行请在设置中安装辅助服务，管理员授权由 macOS 完成。辅助服务只随 App 分发，不会在安装 pkg 时自动安装。

## 下载与更新

在 [Releases](https://github.com/Cooper-Han/RouteDuo/releases) 下载 `RouteDuo-Installer.pkg`。
从 1.1.0 开始，菜单提供“检查更新…”，由 Sparkle 验证更新包签名并安装。辅助服务有变化时，需要在 App 内授权更新一次。旧版需手动安装一次支持更新的新版。

## 功能

- IP / 域名分流地址、备注、拖动排序、导入导出
- 自动启用、开机启动、网络变化监听
- 调整系统网络服务顺序
- 辅助服务修复、请求超时、异常退出路由清理

## 开发与发布

使用 Xcode 打开 `WorkRouteMenu.xcodeproj`。Swift Package Manager 将下载固定版本的 [Sparkle](https://sparkle-project.org)。

发布步骤见 [RELEASING.md](RELEASING.md)。`Build/`、个人 Xcode 配置、证书私钥和凭据均不提交。

当前发布流程使用 Developer ID 签名，尚未执行 Apple 公证，首次安装可能受到 Gatekeeper 限制。
