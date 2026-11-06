# LED Talks for ESP-IDF

An ESP-IDF component that plays LED Talks messages ([protocol](../../docs/protocol.md)) on a
WS2812, a plain GPIO LED, or an LEDC-PWM LED. The encoder is the portable core in `../core`;
this is the timer and the LED driver.

## Adding it to a project

From a checkout, point your project's `CMakeLists.txt` at this directory before
`project.cmake`:

```cmake
set(EXTRA_COMPONENT_DIRS /path/to/led-talks/encoder/esp-idf)
```

The component's name is its directory name, `esp-idf`, so a component that uses it says
`REQUIRES esp-idf`. Its `idf_component.yml` pulls in `espressif/led_strip` (^3) automatically.

## API (`led_talks_esp.h`)

```c
lt_esp_config_t cfg = LT_ESP_CONFIG_WS2812(17); /* RGB-8, 33.3 ms symbols, white "on" */
ESP_ERROR_CHECK(lt_esp_init(&cfg));
ESP_ERROR_CHECK(lt_esp_send(payload, len, true)); /* repeat until lt_esp_stop() */
```

| Function | What |
|---|---|
| `lt_esp_init(cfg)` | Sets up the LED and a periodic `esp_timer` |
| `lt_esp_send(payload, len, repeat)` | Encodes and starts playing; replaces any message in progress |
| `lt_esp_stop()` | Stops at once, LED off |
| `lt_esp_busy()` | True while playing (always, when repeating) |
| `lt_esp_repeat_symbols(len)` | Symbols per repeat including the gap, for timing a stop |

Config fields: `led` (`LT_ESP_LED_WS2812`, `_GPIO`, `_LEDC`), `gpio`, `mode`, `period_us`
(0 is 33333), `on` (the WS2812 colour for OOK and PAM-4), `active_low` (GPIO and LEDC), and
`ledc_freq_hz` (0 is 20000; below 10000 is rejected).

| LED | Modes |
|---|---|
| WS2812 | OOK, PAM-4, RGB-8 |
| LEDC | OOK, PAM-4 |
| GPIO | OOK |

Anything else makes `lt_esp_init()` return `ESP_ERR_INVALID_ARG`. Call the API from tasks, not
ISRs.

## Example

`examples/status/` (ESP32-S3, WS2812 on GPIO17, BOOT button on GPIO0): pressing BOOT sends a
status report in RGB-8, three times.

```sh
. ~/esp/v5.5/esp-idf/export.sh
cd encoder/esp-idf/examples/status
idf.py set-target esp32s3 && idf.py build
```

## Timing notes

- Choose a symbol period of at least three camera frames (33 ms suits a 90 fps or faster
  capture; slower phones need a longer period).
- The timer callback runs in the `esp_timer` task, because `led_strip_refresh()` blocks on the
  RMT. Its jitter is normally well inside the protocol's T/10 budget, but a busy
  higher-priority task can break it; raise `CONFIG_ESP_TIMER_TASK_PRIORITY` if so.
- On a WS2812, prefer RGB-8: each channel is fully on or off, so the LED's slow internal PWM
  never shows. PAM-4 on a WS2812 relies on that PWM and is the weakest choice; LEDC runs at
  10 kHz or faster for that reason.
- Not yet run on hardware.
