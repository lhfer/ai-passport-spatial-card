# Spatial Card 设备协议 v1

三条链路共用同一套消息：**一行一个 JSON 对象**（UTF-8，以 `\n` 结尾，单行 ≤ 512 字节），字段 `t` 是消息类型。
需要应答的命令带 `id`（字符串），接收方回 `{"t":"ack","id":…,"ok":true|false,"err":"…"}`。未知 `t` 一律回 `ack ok:false err:"unknown"` 并忽略。

| 链路 | 传输 | 说明 |
| --- | --- | --- |
| Hub ↔ 设备 | USB Serial/JTAG（`/dev/cu.usbmodem*`，VID 303A） | Hub 发 `hello{muteLogs:true}` 后设备把所有日志改成 `log` 消息，串口上只剩 JSON |
| Vision Pro ↔ 设备 | BLE Nordic UART Service | Service `6e400001-b5a3-f393-e0a9-e50e24dcca9e`，RX `6e400002-…`（VP→设备，Write / Write-no-response），TX `6e400003-…`（设备→VP，Notify）。设备名 `SpatialCard-XXXX`，广播里带 128-bit service UUID，Just-Works 不绑定不加密，MTU 247，长行按 MTU-3 分片、按 `\n` 重组 |
| Hub → Vision Pro | WebSocket `ws://<mac>.local:8787/vp`（单向广播）+ REST | **默认链路**：头显包里的 `Resources/hub.json`（`{"vpURL":"ws://<mac>.local:8787/vp"}`）指向这台 Mac，空间一打开就连；`--hub ws://…` 覆盖它，`--fake-hub <path>` 在模拟器里回放。用它把 `stats/celebrate/set_theme/cmd/notes` 送到 VP（设备不插 USB 时 VP 再经 BLE 转给设备），笔记与封面走同一主机的 REST（见下）。Hub 没起来时 App 照常工作（BLE 那条链路不受影响），只是**没有笔记扇面**，日志里会一直 `[hub] reconnecting …` |

## 主题

`theme ∈ {"base","neon-city","data-nebula"}`。其它世界 id（`code-sea`、`deep-sea`、`paper-valley`）在设备上映射为 `base`，`ack` 里回 `"theme":"base"`。

### 屏幕锁（`CONFIG_CARD_SCREEN_LOCK`，默认 y）

ARKit 参考物体是拿 `CONFIG_CARD_DEFAULT_THEME`（默认 `base`）那张屏训练出来的，所以锁开着时**设备上的主题永不改变**：

- 开机恒显示 `CONFIG_CARD_DEFAULT_THEME`，**无视 NVS 里记住的主题**（也不回写 NVS），启动日志里有一行 `screen lock: theme base`；`hello` 照常上报 `theme`。
- 串口或 BLE 的 `set_theme` 一律回 `{"t":"ack","id":…,"ok":false,"err":"locked"}`，屏幕不动，也不会有 `will_change`/`changed`；`ack` 里**不带 `theme`**，因为什么都没变。
- idle 模式 UP/DOWN 不再切主题，但按键照常经串口 / BLE 上报 `button`。
- 底条（`strip` 覆盖、粉丝数翻页、`celebrate`）、`set_mode`、`stats`、`backlight` 全部不受影响。

## 模式

- `idle`：没有 BLE 中心连接。屏幕显示大字粉丝数；UP/DOWN 本地切主题（便于单独测识别），OK 重放提示音，长按 OK 重新广播并重发 `hello`；按键同时通过串口上报。
- `ar`：BLE 中心已连接（连接即进入，断开即退出）。屏幕**像素级静止**：数字切成低对比"安静"样式，不再有任何本地 UI 反馈；按键只经 BLE 上报；背光走 AR 档位（`CONFIG_CARD_AR_BACKLIGHT_PERCENT`，v3.4 起默认 **85**，即 5 kHz/10-bit PWM——头显相机拍不到闪烁，用来防开灯拍摄时过曝，并给按键闪留出向上到 100 的余量；100 = 直流），**不管 USB 插没插**；任何重绘都走下面的握手。

## 消息一览

`stats` 对象在所有链路里同构：

```json
{"followers":4313,"likes":44000,"notes":128,"delta":5,"ts":1758153600}
```
`delta` = 相比上一采样粉丝净增（≥0，无则 0），`ts` = Unix 秒。设备按 `ts` 去重：`ts` ≤ 已存值则忽略但仍 `ack ok`。

### Hub → 设备（串口）

| 消息 | 字段 | 说明 |
| --- | --- | --- |
| `hello` | `id, hub:"spatial-hub/0.1", muteLogs:true` | 开端口先发；设备回 `hello` + `ack` |
| `stats` | `id, followers, likes, notes, delta, ts` | 每次抓取/模拟后 |
| `celebrate` | `id, delta` | 粉丝净增时紧跟 `stats` 之后发；设备叮一声 + 数字翻页，并经 BLE 转发 |
| `set_theme` | `id, theme` | 面板主题选择；AR 模式下走握手 |
| `set_mode` | `id, mode:"idle"|"ar"` | 显式覆盖（测试用） |
| `play_cue` | `id, cue:"celebrate"|"tick"|"connect"` | 测试 |
| `backlight` | `id, percent:0-100` | 两种模式下都生效。idle：覆盖电池档位，到下一次活动（按键 / `celebrate` / `set_theme`）为止。AR：设置本次 AR 会话的档位，**按键不会清掉它**，只有 `set_mode`（任意模式，含幂等的 `set_mode ar`）和 BLE 连接/断开会重新套用 `CONFIG_CARD_AR_BACKLIGHT_PERCENT`；`percent` 100 = 直流，其余是真实 PWM 占空比。`percent` 缺失或越界 → `ack ok:false err:"percent"` |
| `cmd` | `id, c:"replay"|"celebrate"|"theme"|"director"|"hide"|"show"|"perf", arg?` | 导演命令，设备原样经 BLE 转给 VP（`{"t":"cmd","c":…,"arg":…}`；固件不认命令名，只要求重新序列化后 < 256 字节，否则回 `ack ok:false err:"cmd"`、不转发）；`hide`/`show` 见「Hub → Vision Pro」，`perf` 见「现场性能开关 cmd perf」 |
| `strip` | `id, text?` | 覆盖底条（见下面「底条覆盖」）；无 `text` = 恢复粉丝数 |
| `glow` | `id, ms?:50-1000, kind?:sweep\|flash` | 屏幕上一道白光扫过（或全屏闪）≤ 1 s，像素原样恢复，不走 `will_change` 握手（见「屏幕闪光 glow」）；fw < 0.2.0 回 `ack ok:false err:"unknown"` |
| `sleep` | `id` | 进入深睡（v1 仅测试） |
| `ping` | `id` | 回 `ack` |

### 设备 → Hub（串口）

| 消息 | 字段 | 说明 |
| --- | --- | --- |
| `hello` | `fw, boot, mode, theme, stats{…}, battery{soc,mv}, ble{connected}, heap, backlight` | 开机、收到 `hello` 时、长按 OK 时；`backlight` = 当前实际生效的背光百分比 |
| `ack` | `id, ok, err?, theme?` | 每条命令 |
| `button` | `btn:"up"|"down"|"ok", ev:"click"|"long"` | 仅 idle 模式 |
| `ble` | `connected:bool` | BLE 中心连上/断开 |
| `battery` | `soc, mv, usb:bool, heap, backlight` | 每 30 s；`backlight` 同 `hello` |
| `log` | `lvl:"E"|"W"|"I"|"D", msg` | `muteLogs` 之后，≤ 20 条/s |

### 设备 → Vision Pro（BLE TX）

| 消息 | 字段 | 说明 |
| --- | --- | --- |
| `hello` | 同串口 | 连接后立刻发（此时 mode 已是 `ar`） |
| `button` | `btn, ev` | AR 模式每次按键 |
| `will_change` | `id, kind:"theme"|"stat", theme, region:[x,y,w,h]` | 重绘前，见握手 |
| `changed` | `id, theme` | 重绘完成 |
| `stats` | 同构 | Hub 推送时转发 |
| `celebrate` | `delta, followers` | Hub 推送时转发 |
| `cmd` | `c, arg?` | Hub 导演命令转发 |
| `battery` | `soc, backlight` | 每 60 s |
| `ack` | `id, ok, err?, theme?` | 回应 VP 命令 |

### Vision Pro → 设备（BLE RX）

| 消息 | 字段 | 说明 |
| --- | --- | --- |
| `set_mode` | `id, mode` | 连接后 VP 发 `ar`（默认已是 ar，幂等） |
| `set_theme` | `id, theme` | 进世界（壳球不透明后）/ 需要时 |
| `ack` | `id, ok` | 回应 `will_change` |
| `stats` / `celebrate` / `play_cue` | 同串口 | WS 中继（设备不插 USB 时） |
| `strip` | `id, text?` | 预览笔记时覆盖底条为该笔记点赞数（见「底条覆盖」） |
| `glow` | `id, ms?, kind?` | 识别扫描与召唤时让真实屏幕同步扫一道白光（见「屏幕闪光 glow」） |
| `backlight` | `id, percent` | v4 B2：每次连上都紧跟在 `set_mode ar` 之后发（`set_mode` 会重新套用固件自己的 AR 档位，所以必须在它之后）。App 默认 `100`（直流，没有 PWM），`--ar-backlight 100\|85\|keep` 可改；语义同上面串口表的 `backlight`。代价：档位正好是 100 时，按键背光闪退回"向暗"（见「屏幕闪光 glow」最后一段） |
| `ping` | `id` | 回 `ack` |

### Hub → Vision Pro（WebSocket `/vp`）

`{"t":"stats",…}`、`{"t":"celebrate","delta":5,"followers":4318}`、`{"t":"set_theme","theme":"neon-city"}`、`{"t":"cmd","c":"replay"}`、`{"t":"notes","rev":3,"count":10}`。VP 只读；收到 `stats/celebrate` 时若 BLE 已连则经 RX 转给设备。

`cmd` 的命令名**永远在 `c` 字段里**（VP 按 `c` 解码，缺 `c` 的帧解不出来会被丢弃），合法值同串口表：`replay | celebrate | theme | director | hide | show | perf`。

| 帧 | 含义 |
| --- | --- |
| `{"t":"cmd","c":"hide"}` | 把桌面上的名片收折回设备里（与点击底环收起等价）；世界/笔记扇面照常保留 |
| `{"t":"cmd","c":"show"}` | 再把名片放回桌面 |
| `{"t":"cmd","c":"perf","arg":"cones=off well=off"}` | v4 B4：现场逐层开关桌面上的东西、换名片材质，每条之后开一个新的 5 s `[perf]` 窗口并打出 scene 行（见下一节） |

Hub 侧：面板「隐藏名片 / 显示名片」两个按钮和 `POST /api/cmd` 是同一条路径，请求体 `{"c":"hide"}` 与 `{"cmd":"hide"}` 都接受（`c` 优先），命令名不在上表 → 400 且不广播。

`notes` 是**提示帧**，不带笔记数据：Hub 每次抓取后比较归一化列表（id / 标题 / 点赞 / 置顶 / 类型；`xsec_token` 和封面路径不参与比较），只有真的变了才 `rev++` 并广播一次。VP 收到后若 `rev` 与本地不同就拉 `GET /api/notes`，相同则忽略（`rev` 从 1 开始，0 = Hub 还没抓过）。连接时不会补发，VP 上线后应主动拉一次。

## 现场性能开关 `cmd perf`（v4 B4 §3.5）

第 2 轮真机桌面只有 44–46 fps，嫌疑一长串，但每换一个参数就要重启 App（丢掉会话状态和当时的光线）。`cmd perf` 让审阅者在 Mac 上逐层关掉、打开桌面上的东西，不用重启：

```sh
# 关掉投影锥体和光井，开一个新的 5 s [perf] 窗口
curl -s -X POST http://localhost:8787/api/cmd -H 'content-type: application/json' -d '{"c":"perf","arg":"cones=off well=off"}'
# 只量不改（当前状态再开一个窗口）
curl -s -X POST http://localhost:8787/api/cmd -H 'content-type: application/json' -d '{"c":"perf"}'
# 全部恢复默认
curl -s -X POST http://localhost:8787/api/cmd -H 'content-type: application/json' -d '{"c":"perf","arg":"reset"}'
```

- **`arg` 是一个字符串**（不是对象：设备的 BLE 中继和 VP 的 `cmd` 解码只认标量），由空格或逗号分开的词组成：
  - `层=off` 把这一层移出场景树（之后每一帧都保持移出，不管编排怎么开它）；`层=on` 还给 App，App 照常画它；
  - `tier=low|medium|high`（v4 B5 §4）：把世界的质量档位定住（看门狗不再自动降档）：在世界里立刻生效，在桌面上从下一次进入起生效；`reset` 回到启动时的档位（头显默认 `medium`）。`low` = 星云去掉远景层和三团星云气、银河带的星减半；
  - `material=plain|blur|placeholder`：名片本体的材质（`plain` = 不排背景模糊的 A1 水晶，B4 起的默认；`blur` = B1–B3 的背景模糊；`placeholder` = A4 占位 style，不用任何 A1 材质）。和启动时不同的那种磨砂第一次用时要现场加载两张 ShaderGraph（模拟器约 1.5 s，日志 `[perf] card material: the … frost's graphs loaded in N ms (first use)`）；名片正在出场时等出场结束再换；
  - `reset`：全部回到默认；`all=off` / `all=on`：所有层一起（先 `reset`，再 `all`，再逐层，所以 `all=off desk=on` = 只留桌面）；
  - 什么都不写（或 `status`）：不改任何东西，只开一个新窗口；
  - **`wait=<秒>`**（v4 B5 §1，0–10，也写作 `settle=`）：这条命令的窗口等多久再开。不写时：改了状态的命令等 **2 s**，没改状态的（只量、同一个状态再来一次）不等；
  - **`rehearse=fanout`**（v4 B5 §1，别名 `fan`、`fan-out`）：在桌上**现场重演一次扇出**：先按上面的规则等状态稳定，然后画廊收回名片（`toggleNotesFan`，就是捏名片的那个真实入口），1.6 s 后再扇出；量的是扇出自己的 1.2 s 窗口 `[perf] desk fan out (rehearse #n · <开关状态>)`，收回也有一个 0.8 s 窗口 `[perf] desk collapse (rehearse #n · …)`。带 `rehearse` 的命令**不再开 5 s 状态窗口**（重演的窗口就是测量）。可以和开关写在一条里：`cones=off rehearse=fanout` = 关锥体、等 2 s、重演。
- **层**：

| 层 | 是什么 | 默认 |
| --- | --- | --- |
| `worlds` | 桌面上预建好的两个世界（`world.neon-city`、`world.data-nebula`）在不在场景树里 | **off**（B4 起移出场景树，只在高亮世界币或进入时放回）；`worlds=on` = B3 的桌面，用来 A/B |
| `cones` | 投影的三层锥体（`shimmer`、`coneTop`、`shimmerWide`） | on |
| `rays` | 投影的 10 条光线 | on |
| `well` | 设备外侧一圈光井边缘光 | on |
| `gallery` | 整个画廊：10 张笔记卡（SwiftUI attachment）、它们的拖尾和 twinkle | on |
| `gallery-glass` | 笔记卡的系统玻璃底（`glassBackgroundEffect`，每张一次背景模糊；牌堆两张世界卡同样）。**10-06 用户拍板：默认关 = B5 的便宜磨砂底 frost**（静态渐变，`--note-base` 默认就是 frost）；`gallery-glass=on` 切回系统玻璃（`--note-base glass` 是启动时的同一个），`reset` 回到 frost。卡片本身还在。B5 起切换不再重建卡片（B4 的写法每切一次 10 张卡、10 张封面全部重新加载）。和 `gallery` 分开，才分得清是修一个效果还是重做画廊 | **off**（frost） |
| `trails` | 10 条笔记拖尾（`trail.note`；B4 起卡片静止时本来就停放） | on |
| `twinkle` | 画廊周围漂的金点（`notes.twinkle`） | on |
| `card-particles` | 名片自己的常驻粒子（`card.particles`） | on |
| `rig-dust` | 投影光束里的尘（`rig.dust`） | on |
| `desk` | 桌面本身：光晕、两枚世界币、chip（`surface`） | on |
| `note-fade` | （B5）画廊卡片在飞行里的透明度渐变：on = 整段飞行都在渐变（现在的样子）；off = 飞出时只在前 1/5 渐显、飞回时只在最后 1/5 渐隐，其余时间不透明（`--note-fade quick` 是同一个） | on |
| `flourish` | （B5）画廊落定的点缀：扇出的 3 次 12 粒火花、名片边缘的脉冲、bloom 峰值、桌面涟漪（放下绽开的火花同样）；off = 只留音效 | on |
| `bloom` | （B5）RealityKit 的 bloom：off = 把名片、桌面、小卡、金点、世界里（包括预建世界）的 `BloomComponent` 全部摘掉，on = 放回。纯测量用（魔法光的光晕就是 bloom） | on |
| `hold-dim` | （B5）丢跟踪时名片和整个画廊降到 0.6 的提示：off = 只留边缘呼吸，不降透明度（`--hold-dim off` 是同一个）。第 3 轮的桌面逐层测量都是在这个降暗状态下量的 | on |
| `motes` | （B5）三个常驻发射器（`notes.twinkle` 10/s、`card.particles` 30/s、`rig.dust` 18/s，桌面存活 ≈ 203 粒）的出生率：off = 各 2/3（≈ 137 粒，`--resident-motes lite` 是同一个）。和上面三个单独的层不同，那三个是整个关掉 | on |

- **设成某个状态，不是切换**：同一条命令可能经设备蓝牙和 Hub WebSocket 各到一次，重复执行结果一样；1 s 内收到同一条命令的第二份，只打一行 `again (…) within 1 s: the same command, applied once`，不再开新窗口。**重演是动作**，靠同一条去重保证只演一次；另外一次重演没演完（含扇出窗口报完）时再来一个 `rehearse`，打一行 `#n is still playing — ignored`。
- **重演在哪儿能演**：名片站在桌上、画廊在外面、没有预览、不在世界里、不在手里、名片不在出场中。否则打一行 `[perf] rehearse fanout refused: <原因>`，什么都不做（捏名片在世界里是退出、在预览里是关预览，所以这些地方一律不演）。收回后、扇出前设备被拿起之类，打一行 `no fan-out — …` 并解除这次收回带来的「手动收起」，画廊在下次放下时照常回来。
- **日志**：`[perf] cmd perf "cones=off well=off" (hub) → cones off · well off`，紧接着 `[perf] scene (cmd perf, now): …` 和 `[perf] scene detail (cmd perf, now): …`（切换那一刻的场景），然后 `[perf] cmd perf cones off · well off: the 5 s window opens in 2.0 s`；窗口结束时 `[perf] cmd perf cones off · well off (settled 2.0 s): N frames in 5.0 s, avg … fps, worst … ms`、这个窗口结束时的 scene 行。认不出的词打在同一行末尾（`— ignored: …`），其余照做。上一个窗口还在等或还没跑完就来了新命令：上一个窗口作废，打一行 `the previous window was dropped before it opened` 或 `… was cut short by this command`；所以两条命令之间至少隔 **8 s**（2 s 等待 + 5 s 窗口 + 余量），重演之后隔 8 s。
- **每个 `[perf]` 窗口后面多两种行**（v4 B5）：只要有开关不是默认，任何窗口（拿起变形、放下绽开、手持 5 s、世界……）后面都跟一行 `[perf]  ↳ cmd perf state: cones off · …`，说明这个窗口是在什么状态下量的；如果这期间 App 把关掉的层又打开了（拿起、放下、扇出都会），同一行末尾写 `the app turned back on and the hold took out again: gallery ×3, …`——这就是"关掉的层在桌面 ↔ 手持来回切换时一直关着"的证据。另外每个窗口都跟一行 `[perf] <窗口名> cpu: our systems N ms per frame avg, N ms peak (…)`：本 App 自己的 ECS 系统每帧占主线程多少（按系统列出前五）。
- **长度**：设备的 BLE 中继把整条帧重新序列化后要 < 256 字节，`arg` 控制在 200 字节以内；超长时设备回 `err:"cmd"` 不转发，但 Hub 的 WebSocket 那一份照样到。
- **Hub 要重启一次才认得 `perf`**（运行中的 `tsx` 不会加载新代码）；没重启时 `POST /api/cmd {"c":"perf"}` 回 400。

## Hub REST（Vision Pro 用；`http://<mac>.local:8787`）

| 接口 | 说明 |
| --- | --- |
| `GET /api/notes?limit=10` | `{rev, updatedAt, count, notes:[{id, title, likes, pinned, type:"normal"|"video", coverURL, url, publishedAt}]}`。`limit` 1–10（默认 10，非法值按 10）。`id` 是 24 位小写十六进制；`title` ≤ 80 码点；`coverURL` 是**相对**路径 `/api/notes/<id>/cover`，没有封面时为 `null`；`url` 是带 `xsec_token` 的绝对小红书链接（VP 直接 `openURL`）；`publishedAt` 目前恒为 `null`。列表是最近 10 条：隐藏笔记（仅自己可见 / 已违规）已剔除，置顶已移到最后 |
| `GET /api/notes/:id/cover` | 封面代理（CDN 不认没有 Referer 的请求，头显不应直连 CDN）。磁盘缓存命中直接返回；缺失时单飞抓取（Referer + Chromium UA、10 s 超时、3 MB 上限、magic bytes 判类型）。返回 `Cache-Control: public, max-age=86400` + `ETag`（支持 `If-None-Match` → 304）。不在当前列表里的 id → 404（路径穿越因此也是 404）；没有封面源 → 404；抓到的不是图片 / 上游报错 → 502，并负缓存 10 分钟 |
| `POST /api/strip` | `{"text":"♥1825"}` → 底条覆盖；`{}` → 恢复粉丝数。字形非法 → 400（不下发）。设备没插也返回 200，`device.reason:"disconnected"` |
| `GET /api/state`、`POST /api/scrape|simulate|celebrate|theme|cmd` | 导演面板用；`state.recentNotes = {rev, count, updatedAt}` |

## 底条覆盖（`strip`）

`{"t":"strip","id":"n7","text":"♥1825"}` 把底部动态条 `[0,272,240,48]` 换成给定文本；`{"t":"strip","id":"n8"}`（无 `text`）恢复粉丝数。用于笔记预览：VP 预览一张笔记卡时把该笔记的点赞数推到设备上（BLE），Hub 也能经串口发同样的消息（无头显时验固件）。

- **字形集**：`0123456789.+-k万▲▼♥` 和空格，共 19 个（v1 的 17 个 + `0x20` + `0x2665`）。**不含逗号**，与 `stats_format_followers` / `CardStats.compact` 一致。
- **长度**：1–12 码点。超长或含集外字形 → `ack ok:false err:"glyph"`；Hub / VP 侧应在发送前就拒掉。
- **时序**：走 `kind:"stat"` 握手（`will_change` → 重绘 → `changed`），只改底条矩形，不破坏图像跟踪；端到端约 0.35–0.7 s。顺序是 `will_change` → VP `ack` ≤ 300 ms（超时照样继续）→ **命令自己的 `ack`** → 翻页动画约 600 ms → `changed`，所以**别等 `changed` 才认为命令成功**。文本与底条当前内容相同时设备不重绘，因此没有 `will_change`/`changed` 这一对，只有 `ack`；文本非法时底条保持原样。
- **握手只发给 BLE**：`will_change` / `changed` 由 `handshake_begin()` 经 `send_ble()` 发出，且**只在设备处于 `ar` 模式且已有中心订阅 TX 时**才发（`app_state.c`）。所以：Hub 经串口发 `strip`（或 `set_theme`）而头显没连时，设备**直接重绘**，串口上只有那一条命令 `ack` + 屏幕上的翻页，**不会**有 `will_change`/`changed`，也不会有 300 ms 等待；只有在中心已订阅、却没在 300 ms 内 `ack` 时，固件才打 `will_change <id>: no ack in 300 ms` 警告。上面那条时序描述的是 BLE 那种情况。
- **覆盖期间**：`stats` 照常更新粉丝文本，但不显示；`celebrate` 翻的是**当前底条文本**，不是粉丝数。BLE 断开或 15 min 看门狗到期后自动恢复粉丝数。

## 屏幕闪光 glow（v3.2）

```json
{"t":"glow","id":"g1","ms":300,"kind":"sweep"}
```

真机屏幕上跑一道**短暂的白光**，和头显里的"识别扫描"特效同时发生，好让视频里看得出魔法是从这台设备里出来的；OK 召唤时用同一道光。串口和 BLE 都收，idle / ar 两种模式都生效。

- **参数**：`ms` 50–1000，默认 300；缺失、越界或不是整数（小数、字符串、布尔、null）一律按 300——`700.5` 是按 300 处理，不会被截成 700。`kind` = `"sweep"`（默认）或 `"flash"`，未知值按 `sweep`。`id` 可选，没有 `id` 就不回 `ack`（与其它命令一致）。
- **不走握手**：立刻回 `{"t":"ack","id":"g1","ok":true}`，**在动画结束之前**；**没有** `will_change` / `changed`。因为这道光画在 `lv_layer_top()` 上、结束后对象自删，底下的像素**原样恢复**，头显没有任何东西需要重新学习。同理，`will_change` 握手还在进行中时照样可以 `glow`——它们是彼此独立的两层（正在等 `ack` 的那 300 ms 里，`glow` 会被暂存后立刻补跑，不会被丢掉）。
- **重启语义**：已经有一道光在跑时，**删掉旧的再起新的**，永不排队。
- **时长上限 1 s**：ARKit 参考物体是拿基础主题那张屏训练的，所以这道光必须短。`sweep` 是一条 240 × 24 px 的白条（中间 8 px 全不透明，上下各 8 px 渐隐到 0），在 `ms` 内从 y = 320 走到 y = −24（`lv_anim_path_ease_in_out`）；`flash` 是整屏 240 × 320 白色，前 40 % 的时间 0 → 255、其余时间 255 → 0。注意 LVGL 刷新周期是 33 ms，300 ms 只有 9 帧，白条每帧要跳 40–60 px，真机上可能更像「9 个位置的频闪」而不是一道连续的光——拍片时 `ms` 500–600 会更顺。底条上的粉丝数 / `strip` 覆盖和 4 px 状态点都在光下面照常工作，主题图片一个像素都不动。
- **不受屏幕锁影响**：`CONFIG_CARD_SCREEN_LOCK` 锁的是主题，`glow` 是一层临时覆盖、不是换主题，所以锁开着照样闪。
- **`fw` 门槛**：`hello` 里的 `fw` 从 `0.1.0` 提到 **`0.2.0`**，表示这台设备认识 `glow`。旧固件把它当未知消息，回 `{"t":"ack","id":"g1","ok":false,"err":"unknown"}`，App 据此降级即可（`ok:false err:"lvgl"` 则是新固件抢 LVGL 锁超时，极少见）。
- **看不见的两种情况**：背光已经关掉时（电池上闲置 ≥ 2 h）光是画出来了但屏是黑的——`glow` 不算"活动"，不会把背光唤回来；设备处于深睡时同理。
- **按键背光闪（`CONFIG_CARD_BUTTON_BLINK`，v3.4 起默认 y）**：与 `glow` 无关的另一条通路。AR 稳态背光档位 `CONFIG_CARD_AR_BACKLIGHT_PERCENT` 同时从 100 降到 **85**（真实 PWM 占空比，不再是直流；`hello` / `battery` 的 `backlight` 就报这个 85），于是按键闪**朝远端走**：档位 < 100 时一次 click / long 把背光**拉到 100 保持 120 ms 再回到档位**（默认即 85 → 100 → 85）；只有档位正好是 100、上面没地方可去时才退回老的"向暗"——55 % 保持 60 ms、再走一半、120 ms 回到档位。变暗读起来像故障，变亮才像回应。**纯本地、纯背光**：只有一次 LEDC 占空比写入，按键消抖后 0 ms 就发生，不重绘、不发 `will_change`/`changed`、不改 `hello` / `battery` 上报的名义档位、不受屏幕锁影响；idle 模式、背光为 0、或策略在这 120 ms 里真的改了档位（改档位优先）时什么都不做。协议本身没有任何新增字段。

## 按键（v4 B3，取代 v3 的「OK 单击」和 v2 的「长按 OK」）

AR 模式下三个键只经 BLE 上报（`{"t":"button","btn":"up"|"down"|"ok","ev":"click"|"long"}`），语义全部在 VP 侧，是一张表（`Sources/V4/Pure/V4ButtonMap.swift`，单测 `V4ButtonMapTests`；`DeviceCoordinator.swift` 顶部的注释是同一张表）。两条原则：**没有"按了没反应"**（每次忽略都在日志里说原因），**没有"按一下名片就没了"**（只有长按 OK 会收起）。

| 当前在哪 | UP / DOWN | OK 单击 | 长按 OK |
| --- | --- | --- | --- |
| 世界里，已完全进入（`.inside`） | 不做事（打日志） | **回到桌面**（`exitToDesk`） | 回到桌面 |
| 世界里，进入或退出过场中 | 不做事 | 忽略，打日志 | 忽略，打日志 |
| 笔记预览开着（桌面或手里） | 翻到上一篇 / 下一篇 | 关闭预览 | 关闭预览 |
| 桌面，有高亮（8 s 内按过） | 在环上移动高亮（画廊笔记 → 两枚世界币） | 打开高亮的笔记 / 进入高亮的世界 | **收起** |
| 桌面，没有高亮（也包括设备暂时跟丢的 `held(stale/untracked)`） | 同上 | **等于按一次 DOWN**：高亮落到环的第一项（抬起、金边、chip，0.4 s 后底条 ♥） | 收起 |
| 手里，牌堆抬起了一张 | 抬起上一张 / 下一张 | 世界卡 → 进世界；笔记卡 → 预览 | 收起 |
| 手里，没有抬起（profile） | 同上 | **等于按一次 DOWN**：抬起槽位 0（霓虹城的世界卡，所以 OK、OK 就进霓虹城） | 收起 |
| 名片已收起（金点） | 不做事 | **召唤**：完整重演 v4 认出（`--v3-card`：v3 的 0.6 s 短扫描） | 不做事（已经收起） |
| 名片正在出场（认出还扣着入场，到闭合为止） | 不做事 | 不做事 | 不做事 |
| 拿起丢失收成的金点（B2 §3.4） | 不做事 | 不做事（找回设备时名片自己长回来） | 收起 |
| 还没认出过设备 | 不做事 | 不做事 | 不做事 |

- 每次按键 VP 打一行 `[keys] <键> · <当前在哪> → <做什么>`，例如 `[keys] ok · desk, no highlight → ring +1 (= DOWN)`、`[keys] ok · world (entering / exiting) → ignored (a world is opening or closing: keys wait for it to be fully inside)`；具体动作照旧另有一行 `[ble] ok → show|enter <world>|open <note>|close preview`、`[desk] collapse (long OK)`。
- **收起** = 名片收进设备，变成设备顶边外侧上方一个呼吸的金点（只跟设备，不跟手；取代 v3 的插座光和睡眠星尘）。把设备**扣过去**（法线朝下 > 150° 持续 0.8 s）同样是收起（`[gesture] face down 0.8 s → dismiss`），翻回来不会自动出现——出现只听 OK。导演 `cmd hide` 也走同一条收起。本会话前 3 次收起后 1.5 s，按键一侧淡入一行「OK · 唤醒」，任意按键后淡出。
- **召唤** = 和本会话第一次认出完全相同的路径：光轨从屏幕飞出、画出竖版轮廓、名片在轮廓里金边溶解显形、粉丝数滚动；桌面上落成画廊，手里落成铰链上的名片和牌堆。真屏 `glow` 每次都发；设备提示音 `connect` 每个会话只响一次，之后每次召唤都是 `tick`。
- 捏名片（`ImmersiveView.tapCard`）和桌面的「笔记」芯片（没有连设备时）**不走这张表**：它们保留原来长按 OK 的"展开 / 收起笔记扇面"（`NoteFanMachine.longOK`，收起后本会话不再自动展开）。
- 首次识别是否自动出场由启动参数 `--auto-show first|always|never` 决定，默认 `first`。

v3 的旧语义（已删除）：OK 单击在桌面没有高亮时 = 收回名片、在手里 profile 时 = 收回、在世界里 = 忽略；长按 OK 在桌面 = 展开 / 收起笔记扇面。拍摄规则"召唤后的第一下必须是 DOWN"随之作废。

## 长按 OK

idle 模式长按 OK 仍是「重新广播 + 重发 `hello`」。AR 模式下（`{"t":"button","btn":"ok","ev":"long"}`）见上表「长按 OK」一列：世界里（完全进入后）→ 回桌面；预览开着 → 关闭预览；其余有名片的地方 → **收起**（v4 B3）。

## 切屏握手（保护持久识别）

1. 设备收到会改变屏幕像素的命令（`set_theme`，或粉丝数 / 底条文本变化要翻页）。
2. AR 模式**且已有 BLE 中心订阅 TX** 时：设备先经 BLE 发 `will_change{id,kind,theme,region}`，等 VP `ack` **≤ 300 ms**（超时照样继续，并打一条 `no ack in 300 ms` 警告）。不满足这两个条件（idle 模式，或 AR 但没有中心）时**没有握手**：直接重绘，也不会有 `changed`。
3. VP 收到 `will_change`：进入 `held(.theme)`，冻结最后姿态（上限 3 s）。
4. 设备在 `bsp_lvgl_lock` 下重绘并 `lv_refr_now`，然后发 `changed{id,theme}`。
5. VP 收到 `changed`：把期望参考图切到新主题。**v2 起这只决定"哪张参考图可以接管姿态"，与显示无关**：名片在重捕获之前保持冻结、**永远不会因此隐藏**（`graceTimeout` = ∞，丢图像只冻结）。v1 的"主题解除后 8 s 重捕获窗口、窗口外收起"只在 `--legacy-hide` 下才有（6 s 宽限 / 主题 8 s / 世界 6 s）。
6. 世界内（VP 已暂停跟踪）VP 对 `will_change` 立即 `ack`，不进入保持。
7. `kind:"stat"` 只改底部动态条（`region` 给出像素矩形），VP 可以忽略。

Idle 模式没有握手：直接重绘。

## 示例

```
H→D {"t":"hello","id":"h1","hub":"spatial-hub/0.1","muteLogs":true}
D→H {"t":"hello","fw":"0.2.1","boot":7,"mode":"idle","theme":"base","stats":{"followers":4313,"likes":44000,"notes":128,"delta":0,"ts":1758150000},"battery":{"soc":88,"mv":4060},"ble":{"connected":false},"heap":181240,"backlight":100}
D→H {"t":"ack","id":"h1","ok":true}
H→D {"t":"stats","id":"s1","followers":4318,"likes":44012,"notes":128,"delta":5,"ts":1758153600}
D→H {"t":"ack","id":"s1","ok":true}
H→D {"t":"celebrate","id":"c1","delta":5}
D→VP {"t":"celebrate","delta":5,"followers":4318}
VP→D {"t":"set_theme","id":"v9","theme":"neon-city"}
D→VP {"t":"will_change","id":"w3","kind":"theme","theme":"neon-city","region":[0,0,240,320]}
VP→D {"t":"ack","id":"w3","ok":true}
D→VP {"t":"changed","id":"w3","theme":"neon-city"}
D→VP {"t":"ack","id":"v9","ok":true,"theme":"neon-city"}
```
