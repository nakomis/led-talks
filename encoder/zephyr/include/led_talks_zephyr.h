/* LED Talks on Zephyr: plays an encoded message on a GPIO LED (OOK) or a PWM LED (OOK or
 * PAM-4), one symbol per period, from a k_timer. */
#ifndef LED_TALKS_ZEPHYR_H
#define LED_TALKS_ZEPHYR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <zephyr/drivers/gpio.h>
#ifdef CONFIG_LED_TALKS_PWM
#include <zephyr/drivers/pwm.h>
#endif

#include "led_talks.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Symbol period used when period_us is 0: 33.3 ms, 30 symbols a second. The kernel timer
 * rounds it to a whole tick (about 30.5 us on a 32768 Hz clock), which is far inside T/10. */
#define LT_ZEPHYR_DEFAULT_PERIOD_US 33333

/* Off symbols between repeats (and after a single send); at least LT_MIN_GAP. */
#define LT_ZEPHYR_GAP_SYMBOLS 8

/* Longest frame, in symbols: 255 bytes in OOK (see lt_frame_symbols()). */
#define LT_ZEPHYR_MAX_SYMBOLS 2100

/* A GPIO LED, on/off only (so OOK). The pin is configured as an output, off; the devicetree
 * flags decide active-high or active-low. Returns 0, or -EINVAL / -ENODEV / a driver error.
 * Call one init function, once. */
int lt_zephyr_init_gpio(const struct gpio_dt_spec *led, uint32_t period_us);

#ifdef CONFIG_LED_TALKS_PWM
/* A PWM LED, OOK or PAM-4. The PWM period must be at most 100 us (10 kHz or faster, protocol
 * §2); polarity comes from the devicetree flags. The timer callback runs in interrupt context
 * and calls pwm_set_dt() there: that is safe on nRF PWM (it only writes a duty-cycle register
 * in RAM), but check your SoC's driver before using it elsewhere. */
int lt_zephyr_init_pwm(const struct pwm_dt_spec *led, lt_mode_t mode, uint32_t period_us);
#endif

/* Encodes payload and starts playing it, replacing any message in progress. With repeat it
 * loops, separated by a gap, until lt_zephyr_stop(). Returns 0, -EINVAL (no payload),
 * -EMSGSIZE (doesn't encode), or -ENODEV (not initialised). Safe from any thread; the
 * payload is encoded at once, not kept. */
int lt_zephyr_send(const uint8_t *payload, size_t len, bool repeat);

/* Stops at once and turns the LED off. */
void lt_zephyr_stop(void);

/* True while a message is playing (always, if repeating). */
bool lt_zephyr_busy(void);

/* Symbols in one repeat of a payload (frame plus gap), for timing a stop; 0 if invalid. */
size_t lt_zephyr_repeat_symbols(size_t len);

#ifdef __cplusplus
}
#endif

#endif /* LED_TALKS_ZEPHYR_H */
