# LED Talks for Zephyr

A Zephyr module that plays LED Talks messages ([protocol](../../docs/protocol.md)) on a GPIO
LED (OOK) or a PWM LED (OOK or PAM-4). The encoder is the portable core in `../core`; this is
the timer and the LED driver.

## Adding it to a project

Add the module directory to your build, and enable it in `prj.conf`:

```sh
west build ... -- -DEXTRA_ZEPHYR_MODULES=/path/to/led-talks/encoder/zephyr
```

```
CONFIG_GPIO=y
CONFIG_LED_TALKS=y
CONFIG_LED_TALKS_PWM=y   # only for PWM LEDs; selects CONFIG_PWM
```

## API (`led_talks_zephyr.h`)

```c
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

lt_zephyr_init_gpio(&led, 0);          /* 0 is 33333 us */
lt_zephyr_send(payload, len, true);    /* repeat until lt_zephyr_stop() */
```

| Function | What |
|---|---|
| `lt_zephyr_init_gpio(gpio_dt_spec, period_us)` | GPIO LED, OOK only |
| `lt_zephyr_init_pwm(pwm_dt_spec, mode, period_us)` | PWM LED, OOK or PAM-4; the PWM period must be at most 100 us |
| `lt_zephyr_send(payload, len, repeat)` | Encodes and starts playing; replaces any message in progress |
| `lt_zephyr_stop()` | Stops at once, LED off |
| `lt_zephyr_busy()` | True while playing (always, when repeating) |
| `lt_zephyr_repeat_symbols(len)` | Symbols per repeat including the gap, for timing a stop |

Active-high or active-low comes from the devicetree flags. Sends from different threads must
be serialised by the caller.

## Sample

`samples/status/` uses the `led0` and `sw0` aliases; pressing the button sends a status report
in OOK, three times. The Pro Micro nRF52840 has `led0` (P0.15) but no button, so the sample's
board overlay adds `sw0` on P0.17 (wire it to GND).

```sh
source ~/ncs/.venv/bin/activate
cd ~/ncs/v3.4.2
west build -p --no-sysbuild -b promicro_nrf52840/nrf52840/uf2 -d build/talk3 \
	<repo>/encoder/zephyr/samples/status -- -DEXTRA_ZEPHYR_MODULES=<repo>/encoder/zephyr
```

Also builds for `nrf52dk/nrf52832`. There is no PWM variant of the sample (the Pro Micro's
`pwm-led0` has a 20 ms period, far too slow); `CONFIG_LED_TALKS_PWM=y` compiles.

## Timing notes

- Choose a symbol period of at least three camera frames.
- The `k_timer` expiry runs in interrupt context. `gpio_pin_set_dt()` is fine there.
  `pwm_set_dt()` is called there too: on nRF PWM that only writes a duty-cycle value to RAM
  for the next period, so it is ISR-safe in practice. That is an assumption; a PWM behind a
  bus (I2C, SPI) would not be, and needs a work-queue port.
- The kernel rounds the period to a whole tick (about 30.5 us at 32768 Hz), and a periodic
  timer does not accumulate drift.
- PWM at 10 kHz or faster keeps the PWM itself out of the camera's exposure.
- Not yet run on hardware.
