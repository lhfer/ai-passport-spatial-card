# AI Passport firmware

FoloToy AI Passport 的 ESP32-C3 固件：LCD 名片、涨粉提示音、实体按键、BLE 与 USB 串口联动。使用 ESP-IDF 5.5.3 和 LVGL 9。

## 先验证，再刷入

设备的整片 Flash 可能包含自己的配置。刷机前请自行备份，备份保存在本地；本仓库不包含作者设备的备份镜像。

```bash
source ~/esp/esp-idf-v5.5.3/export.sh
./tools/validate.sh --static
idf.py set-target esp32c3
idf.py build
idf.py merge-bin -o spatialcard-full.bin
```

先关闭**自己运行的** Hub 或其他串口占用程序，再将实际端口填入：

```bash
esptool.py --chip esp32c3 --port <YOUR_SERIAL_PORT> --baud 921600 \
  --before default_reset --after hard_reset \
  write_flash --flash_mode dio --flash_freq 80m --flash_size 8MB \
  0x0 build/spatialcard-full.bin
```

完整验证：`./tools/validate.sh --all`。`--static` 运行 C 主机测试和资源一致性检查，不访问设备。`--firmware` 做隔离的 ESP-IDF 构建和合并镜像校验。

## 换成自己的名片

在仓库根目录编辑 `assets/card/card.json`、替换头像，运行 `cd hub && pnpm screens`。该命令同时生成固件主题位图和 visionOS 参考图，避免屏幕与 App 不一致。

## 来源

BSP 基于 [FoloToy/ai-passport](https://github.com/FoloToy/ai-passport)，保留上游 MIT 许可和本地修改说明，见 [`components/bsp/UPSTREAM.md`](components/bsp/UPSTREAM.md)。cJSON 的许可在 `tests/vendor/cJSON/LICENSE`。
