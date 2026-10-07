# Extended 物体跟踪模型

模型随源码下载：[AI-Passport-Smoked-Vibe-extended.referenceobject](../visionos/SpatialCard/Resources/objects/AI-Passport-Smoked-Vibe-extended.referenceobject)。

| 项目 | 值 |
| --- | --- |
| 目标 | 烟灰透明外壳的 FoloToy AI Passport |
| 训练方式 | Create ML，从 3D CAD 模型训练 |
| 训练模式 | `extended` |
| 观察角度 | `all-angles`；不排除底面和背面 |
| 模型几何包围盒 | 60 × 95 × 8.5 mm |
| 公开包大小 | 约 7.6 MiB |
| 许可 | MIT，见仓库 LICENSE |

## 隐私处理

参考物体原来包含训练用的 USDZ 模型及屏幕贴图。公开版本通过 Apple 的 Reference Object Compiler 去掉内嵌 USDZ，同时移除 AppleDouble 附加元数据，并将作者选择的 MIT 许可写入包元数据。

**检测器、跟踪器及其权重文件、几何与视角参数均保持原内容。** 8 个模型文件已经与原包逐字节比较。公开包校验值在 [`model-manifest.json`](../visionos/SpatialCard/Resources/objects/model-manifest.json)，可运行：

```bash
python3 tools/check-public-release.py
```

移除预览 USDZ 是 [Apple 支持的发布流程](https://developer.apple.com/documentation/visionos/implementing-object-tracking-in-your-app)。它不会重新训练模型，也不会从学习到的特征中“撤销”原训练数据；本次处理移除的是能直接提取和查看的源图像。

## 使用范围

将整个 `.referenceobject` 文件保存在 `Resources/objects/`，通过 XcodeGen 生成工程后会进入 App bundle。不需要先运行训练，也不需要 Git LFS。

模型在特定外壳和训练外观下制作。不同颜色、外壳、屏幕图案、灯光或遮挡可能影响识别；本仓库匿名主题屏在真实设备上的识别表现还需要使用者验证。真实模型识别不在模拟器中运行。

没有附带原始私人 CAD 贴图和训练工作目录。若要重新训练，请准备自己拥有使用权的 USDZ，在适当的 Xcode 工具链中运行：

```bash
xcrun createml objecttracker --training-mode extended --all-angles \
  --source your-device.usdz --output your-device.referenceobject
```

命令与当前安装的工具链对应，以 `xcrun createml objecttracker --help` 为准。
