# Spatial Card for visionOS

用 SwiftUI、RealityKit 和 ARKit 把实体 AI Passport 变成空间名片、作品牌堆与世界入口。当前代码需要 **visionOS 27 / Xcode 27 工具链**。

## 构建

```bash
xcodegen
xcodebuild -scheme SpatialCard -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

若安装在 `Xcode-beta.app`，先设置 `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。

模拟脚本的完整启动与测试命令见 [开发指南](../../docs/development.md)。`Tools/` 中的 `fake-track-*`、`fake-device-*` 和 `fake-notes.json` 可在没有硬件时驱动实际 App。

## 真实设备

1. `xcodegen` 后用 Xcode 打开生成的工程。
2. 在 Signing & Capabilities 中选择自己的开发团队，必要时修改 Bundle ID。
3. 按 Hub 指南启动自己的 Hub。在 `Resources/hub.json` 中填入 `{"vpURL":"ws://your-mac.local:8787/vp"}`，将 `your-mac` 换成自己的 Mac 主机名。
4. 重新构建并部署到 Vision Pro。允许世界感知、蓝牙及本地网络权限。
5. 运行已刷入本项目固件的 AI Passport，先保持屏幕可见、光照充足，再尝试拿起与放下。

默认的 `hub.json` 是空对象，首次运行不会连接任何作者机器。请勿将自己的主机地址和签名配置提交到公开仓库。

## 跟踪与资源

- `Resources/objects/` 自带匿名化后的 Extended 参考物体，加载时保留物体跟踪能力。[模型说明](../../docs/extended-model.md)。
- `Resources/card.json`、LCD / 参考图由 `cd ../../hub && pnpm screens` 统一生成。
- `Resources/worlds/` 包含运行所需的世界资源；请保留目录层级。
- `--lab materials|ribbon|grounding|card` 可以进入独立的视觉实验场景；`--lab-night` 提供暗色背景。
- `--device-proxy` 在模拟器中显示虚拟设备，不能当作实物识别通过的证据。

在真实设备中体验对象跟踪与按键流程；模拟器用于逻辑测试和动效预览。已知的跟踪、粒子过场与透明度问题见 [已知问题](../../docs/known-issues.md)。
