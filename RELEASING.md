# 发布 RouteDuo

## 签名与密钥

主 App、辅助程序使用同一 Apple Team。修改 Team 时也必须修改 `PrivilegedHelper/main.swift` 中的客户端签名校验要求。安装脚本中的 Developer ID 名称可用环境变量覆盖。

Sparkle 更新签名使用独立 Ed25519 密钥，保存在 macOS 钥匙串，账号名为 `RouteDuo`。工程 Info.plist 的 `SUPublicEDKey` 仅包含公钥。不得将私钥、p12、Apple ID 密码、GitHub token 上传到仓库。

使用 Sparkle 官方发行包的 `bin/generate_keys --account RouteDuo` 创建或读取公钥。换电脑前请根据官方工具说明安全备份该钥匙串密钥；不要重新生成后直接替换公钥，否则旧版将无法验证更新。

## 每次发布

1. 在主 App 两个配置中递增 `CURRENT_PROJECT_VERSION`，更新 `MARKETING_VERSION`。构建号必须始终递增。
2. 执行 `./Installer/build-pkg.sh` 构建并签名 App、辅助程序和安装包。
3. 执行 `SPARKLE_TOOLS=/path/to/Sparkle/bin ./Scripts/prepare-update.sh`，生成更新 zip 和已验证的 appcast。
4. 在 GitHub 创建 `v版本号` Release，上传 `Build/Updates/版本号-构建号/` 中的 `appcast.xml`、App zip 和安装 pkg。三个文件应来自同一次构建。
5. 发布后检查 `https://github.com/Cooper-Han/RouteDuo/releases/latest/download/appcast.xml`，并用旧版测试“检查更新”。

更新会先关闭分流再退出。新版启动后检查辅助程序是否匹配，需要时由用户授权更新。当前没有 Apple 公证步骤。

## GitHub 首次上传

工程完成整理后提交到仓库 main 分支；保留仓库原有 LICENSE。Git 推送需要本机已登录 GitHub。上传 Release 可在网页完成，或安装并登录 GitHub CLI 后使用 `gh release create`。
