<div align="center">
  <img src="docs/media/hero.svg" width="100%" alt="Spatial Card — 把一张名片，变成一个小宇宙。" />
  <p><b>你的名片，从掌心走进空间。</b></p>
  <p>AI Passport × Apple Vision Pro · 真实设备 · 空间画廊 · 沉浸式世界</p>
  <p><a href="README.en.md">English</a> · <a href="#先玩起来">快速开始</a> · <a href="docs/extended-model.md">Extended 模型</a> · <a href="docs/development.md">开发指南</a></p>
</div>

把 AI Passport 放在桌上，戴上 Vision Pro。一道金色光轨勾出名片，你的作品在周围展开。拿起设备，画廊收拢成手中的牌；按下实体按键，就能翻阅作品，或者走进霓虹夜城与数据星云。

**Spatial Card 是一个可自己改、自己搭的空间名片实验。** 源码、固件、示例素材和已经训练好的 Extended 物体跟踪模型，都在这里。

![金色光轨勾勒名片，作品在空间中展开](docs/media/recognition.gif)

*公开版 App 的 visionOS 模拟器录制，使用匿名示例数据与虚拟设备。展示的是实际运行的动画；真实物体跟踪需要 Vision Pro 与 AI Passport。*

## 一张名片，可以发生什么？

- **看一眼，名片亮相。** 金色光轨、纸雕般的头像层次、会滚动的数字，让自我介绍有一点仪式感。
- **拿起来，作品跟你走。** 桌上的作品画廊收成掌心牌堆，实体按键负责翻页，注视和捏合负责探索。
- **按一下，换个世界。** 从桌面进入霓虹夜城、数据星云，再通过空间小名片回到原处。
- **有新关注，一起庆祝。** 配好自己的数据后，屏幕数字、设备提示音和空间光效共同响应；也可以在 Hub 面板中模拟一次。

![手持名片的光轨显形与作品牌堆](docs/media/handheld.gif)

## 先玩起来

### 没有硬件，也能先看一看

需要 **Node.js 24+** 和 **pnpm 10**：

```bash
git clone https://github.com/lhfer/ai-passport-spatial-card.git
cd ai-passport-spatial-card/hub
pnpm install --frozen-lockfile
pnpm demo
```

打开 **http://localhost:8788**。试试「模拟新粉丝 +5」、刷新和主题控制，看看示例数据怎样流动。离线演示包含 10 张原创示例封面，无需登录，不连接串口，刷新也不会访问小红书。空间动画在 Vision Pro App 或模拟器中运行。

想直接看空间效果？按 [模拟器指南](docs/development.md#visionos-模拟器) 构建 App，启动内置的设备与跟踪演示脚本，无需购买硬件。

### 想让它从真实设备里“长出来”

| 你需要 | 用来做什么 |
| --- | --- |
| FoloToy AI Passport | 显示名片、接收按键、播放提示音 |
| Apple Vision Pro，visionOS 27+ | 运行空间名片、物体跟踪和沉浸式世界 |
| Mac，Xcode 27 工具链，XcodeGen | 编译 visionOS App；选择自己的签名团队 |
| ESP-IDF 5.5.3、数据 USB-C 线 | 编译、安装 AI Passport 固件 |
| Node.js 24+、pnpm 10 | 运行 Hub；需要实时数据时再登录自己的账号 |

1. 在 [`assets/card/card.json`](assets/card/card.json) 中填写自己的名片，替换头像后运行 `cd hub && pnpm screens`。
2. 按 [固件指南](firmware/ai-passport-card/README.md) 备份设备并构建、刷入固件。
3. 按 [Hub 指南](hub/README.md) 配置自己的小红书主页与本地登录态。
4. 按 [visionOS 指南](visionos/SpatialCard/README.md) 选择自己的签名团队、配置 Hub 地址并运行。

## Extended 模型已经带上了

不用从头等待训练。[`AI-Passport-Smoked-Vibe-extended.referenceobject`](visionos/SpatialCard/Resources/objects/AI-Passport-Smoked-Vibe-extended.referenceobject) 随仓库直接下载，约 **7.6 MiB**，无需 Git LFS 或额外账号。

它由 AI Passport 的 3D 模型以 **Extended / all angles** 训练。公开包保留训练权重、尺寸和跟踪参数，移除了内嵌的私人预览贴图。校验值、适用设备和限制见 [模型说明](docs/extended-model.md)。换外壳、颜色或屏幕内容之后，需要在自己的设备上重新验证跟踪表现。

## 里面有什么

| 路径 | 内容 |
| --- | --- |
| [`visionos/SpatialCard/`](visionos/SpatialCard/) | SwiftUI、RealityKit、ARKit App，空间动效、场景、模拟脚本和测试 |
| [`firmware/ai-passport-card/`](firmware/ai-passport-card/) | ESP32-C3 固件：LCD、按键、音频、BLE 和 USB 串口 |
| [`hub/`](hub/) | 本地控制面板、数据同步、封面代理和离线演示 |
| [`assets/card/`](assets/card/) | 名片配置、头像与屏幕生成器 |
| [`tools/`](tools/) | 原创示例素材生成、资源管线与开发辅助工具 |
| [`docs/protocol.md`](docs/protocol.md) | 三端通信协议 |

## 当前边界

这是持续探索中的原型，基于 B5 版本整理。斜视、背面和遮挡会影响物体识别；桌面过场仍有粒子性能优化空间，跟丢时的透明度和重新定位也还需要打磨。模拟器无法验证真实跟踪、透视画面或头显帧率。详见 [已知问题](docs/known-issues.md)。

接入真实账号后，登录态、笔记缓存和个人配置只应保存在自己的机器。Hub 的真实设备模式供可信局域网使用，没有互联网服务的账号与权限系统。详见 [隐私与安全](SECURITY.md)。

## 一起做点空间里的小东西

可以替换名片、设计自己的作品封面，或者为它加入新的空间世界。欢迎带着复现步骤、截图或小演示来提 Issue / PR；贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。

项目原创代码、公开示例素材及随附训练模型采用 **[MIT License](LICENSE)**。第三方 BSP、cJSON、CC0 场景资源保留各自许可，见 [第三方说明](THIRD_PARTY_NOTICES.md)。这是独立社区项目。
