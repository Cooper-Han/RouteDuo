# 发布 RouteDuo

## 签名与密钥

主 App、辅助程序使用同一 Apple Team。修改 Team 时也必须修改 `PrivilegedHelper/main.swift` 中的客户端签名校验要求。安装脚本中的 Developer ID 名称可用环境变量覆盖。

Sparkle 更新签名使用独立 Ed25519 密钥，保存在 macOS 钥匙串，账号名为 `RouteDuo`。工程 Info.plist 的 `SUPublicEDKey` 仅包含公钥。不得将私钥、p12、Apple ID 密码、GitHub token 上传到仓库。

使用 Sparkle 官方发行包的 `bin/generate_keys --account RouteDuo` 创建或读取公钥。换电脑前请根据官方工具说明安全备份该钥匙串密钥；不要重新生成后直接替换公钥，否则旧版将无法验证更新。

## 每次发布

1. 更新主 App 的 `MARKETING_VERSION`。打包脚本自动将 `CURRENT_PROJECT_VERSION` 设为上海日期加两位序号（例如 `2026110401`），写回 Debug/Release 两个配置。失败构建也消耗序号；同日最多 99 次；时钟回拨时继续沿用较大的已有日期递增，避免更新号倒退。打包必须串行执行，并将生成后的工程配置提交。
2. 执行 `./Installer/build-pkg.sh` 构建并签名 App、辅助程序和安装包。
3. 执行 `SPARKLE_TOOLS=/path/to/Sparkle/bin ./Scripts/prepare-update.sh`，生成更新 zip 和已验证的 appcast。
4. 在 GitHub 创建 `v版本号` Release，上传 `Build/Updates/版本号-构建号/` 中的 `appcast.xml`、App zip 和安装 pkg。三个文件应来自同一次构建。
5. 发布后检查 `https://github.com/Cooper-Han/RouteDuo/releases/latest/download/appcast.xml`，并用旧版测试“检查更新”。

更新会先关闭分流再退出。新版启动后检查辅助程序是否匹配，需要时由用户授权更新。当前没有 Apple 公证步骤。

## GitHub 首次上传

工程完成整理后提交到仓库 main 分支；保留仓库原有 LICENSE。Git 推送需要本机已登录 GitHub。上传 Release 可在网页完成，或安装并登录 GitHub CLI 后使用 `gh release create`。

## 辅助程序独立版本

主 App 使用 XPC healthCheck 返回的 `RouteDuoHelper/2` 判断辅助程序版本，不比较带签名的可执行文件字节。只修改主 App 无需重新安装辅助程序。发布辅助程序功能或协议变更时，必须同时递增 `PrivilegedHelper/main.swift` 的版本响应和主 App 的 `requiredHelperVersion`，才会提示用户授权更新。签名和服务连通性仍由系统及健康检查验证。
