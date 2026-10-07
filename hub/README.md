# Spatial Card Hub

把桌上的 AI Passport、Vision Pro 与自己的内容连接起来。网页面板提供模拟涨粉、庆祝、主题切换、显示 / 收起和性能调试等控制。

## 离线体验

```bash
pnpm install --frozen-lockfile
pnpm demo
```

打开 http://localhost:8788。示例数据、10 张封面均为本地文件；演示不打开串口，不调用抓取器，刷新按钮也只更新示例数据。演示状态写在被忽略的 `data/demo/`，默认仅监听回环地址。`PORT=8899 pnpm demo` 可换端口。

## 接上自己的账号与设备

1. 编辑仓库的 `assets/card/card.json`，把 `xhs.userId` 改成自己的主页 ID；替换头像。
2. `pnpm screens` 重新生成三张主题屏、固件位图和 visionOS 参考图。
3. `pnpm exec playwright install chromium` 安装登录使用的浏览器。
4. `pnpm hub login` 在本机浏览器里登录自己的小红书账号。
5. 数据 USB-C 线连接已安装本项目固件的 AI Passport，运行 `pnpm hub start`。
6. 面板默认 http://localhost:8787；将 Mac 的局域网地址填入 visionOS 的 `Resources/hub.json`。

真实设备模式监听局域网，供同一可信 Wi-Fi 的头显和遥控面板连接。它没有身份验证，请勿端口转发到公网。

## 常用命令

| 命令 | 用途 |
| --- | --- |
| `pnpm demo` | 无账号、无硬件的离线面板 |
| `pnpm hub start` | 串口、自动抓取和控制面板 |
| `pnpm hub scrape` | 手动同步一次 |
| `pnpm hub send '{"t":"celebrate","delta":5}'` | 给设备发送一次庆祝 |
| `pnpm screens` | 从名片配置重建所有屏幕资源 |
| `pnpm typecheck && pnpm test` | 类型检查与测试 |

Node.js 24+、pnpm 10。可通过 `PORT`、`CARD_PATH`、`HUB_DATA_DIR`、`SCRAPE_INTERVAL_MIN`、`QUIET_HOURS` 配置；`HUB_NO_DEVICE=1` 只关闭串口，仍会运行抓取器，需要完全离线时请用 `pnpm demo`。

`data/` 包含登录态、抓取内容、封面、诊断文件，全部排除在 Git 之外。公开提问时不要附上这个目录。小红书页面可能要求登录或改变布局；失败时保留上次数据，不把计数清零。
