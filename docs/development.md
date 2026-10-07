# 开发与验证

## 环境

- Node.js 24+，pnpm 10：Hub 和屏幕生成。
- CMake、C 编译器：固件主机测试。
- Xcode 27 工具链、visionOS 27 模拟器、XcodeGen：空间 App。
- ESP-IDF 5.5.3：仅在构建固件时需要。

如果 SDK 在 Xcode beta 中，先 `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。

## visionOS 模拟器

```bash
cd visionos/SpatialCard
xcodegen
xcrun simctl list devices available
```

启动一个 visionOS 27 模拟器，以下命令中的 `<SIMULATOR_ID>` 替换成其 ID：

```bash
xcodebuild -scheme SpatialCard -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
xcrun simctl install <SIMULATOR_ID> build/dd/Build/Products/Debug-xrsimulator/SpatialCard.app
xcrun simctl launch --console <SIMULATOR_ID> org.spatialcard.spatialcard \
  --fake-track fake-track-b4-hand-stills.json \
  --fake-device demo-handheld.json \
  --fake-notes fake-notes.json --device-proxy --lab-night --exit-after 30
```

这是实际产品代码的手持显形、收起和召唤流程，数据由本地脚本提供。退出等待后可在其他场景复用模拟器。App 不会默认连接 Hub。

## 测试

```bash
cd hub
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
cd ../firmware/ai-passport-card
./tools/validate.sh --static
```

visionOS 单测先构建 App，再构建 / 运行测试，复用同一个 DerivedData 目录：

```bash
cd visionos/SpatialCard
xcodegen
xcodebuild -scheme SpatialCard -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme SpatialCard -destination 'platform=visionOS Simulator,id=<SIMULATOR_ID>' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO test
```

真机 target 的无签名编译可用 `-destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO build`；部署时必须换成自己的签名团队。

## 生成匿名示例素材

```bash
node tools/create-demo-assets.mjs
cd hub && pnpm screens
```

生成器使用原创 SVG 几何图形，不下载图片。头像分层、作品封面及遮罩全部由它生成。`pnpm screens` 将名片配置同步到固件和 visionOS；发布前重新审阅这些衍生资源。

## 仓库约定

- `Resources/` 是运行资源，不是缓存；Extended 模型必须保留。
- `build/`、`build-host/`、依赖、登录状态和开发者签名配置不提交。
- 真机日志可能包含用户内容和设备标识，提 Issue 前请脱敏。
- 发布前运行 `python3 tools/check-public-release.py` 和 `gitleaks git --redact`。
