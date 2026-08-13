# SCCS ESP32-S3 firmware

ESP32-S3-WROOM-1U firmware for the two lighting/analog MCUs.

Host protocol (UART1, 115200 8N1): `SET` / `RAMP` / `GET` / `ANALOG` / `GETVCC` / `GETALL`.

| Sketch | Role | Pi UART | ESP host UART | PWM GPIOs | Analog GPIOs |
|--------|------|---------|---------------|-----------|--------------|
| `esp32_1/` | ESP32-1 | `uart3` → `/dev/ttyAMA2` (Pi GPIO 4/5) | GPIO 17 RX / 18 TX | 4–11 | 1 (water) |
| `esp32_2/` | ESP32-2 | `uart4` → `/dev/ttyAMA3` (Pi GPIO 8/9) | GPIO 17 RX / 18 TX | 4–11 | 1, 2 |

Shared core: `SccsEspFirmware.h` (copied into each sketch folder).

## Build / flash

- Chip: **ESP32-S3** / **ESP32-S3-WROOM-1U**
- Upload over the module’s programming USB interface (not the Pi host UART)

```bash
arduino-cli core update-index
arduino-cli core install esp32:esp32

arduino-cli compile --fqbn esp32:esp32:esp32s3 esp32/esp32_1
arduino-cli upload -p /dev/ttyACM0 --fqbn esp32:esp32:esp32s3 esp32/esp32_1

arduino-cli compile --fqbn esp32:esp32:esp32s3 esp32/esp32_2
arduino-cli upload -p /dev/ttyACM0 --fqbn esp32:esp32:esp32s3 esp32/esp32_2
```

## ADC / water level

- 12-bit reads (0–4095), 64-sample average — matches `water_adc_max = 4095` on the Pi
- `GETVCC` returns `3300` (mV of the 3V3 rail for the 150 Ω pull-ups)
- Water sender on ESP32-1 GPIO 1: empty ~240 Ω, full ~33 Ω (`config/sccs.conf` `[sensors]`)
