/* Press the button: blink a status report on the LED, in OOK. */
#include <stdio.h>

#include <zephyr/kernel.h>

#include "led_talks_zephyr.h"

#define REPEATS 3
#define PERIOD_US LT_ZEPHYR_DEFAULT_PERIOD_US

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
static const struct gpio_dt_spec button = GPIO_DT_SPEC_GET(DT_ALIAS(sw0), gpios);

static size_t build_status(uint8_t *buf, size_t cap)
{
	lt_status_t st;

	lt_status_init(&st, buf, cap);
	lt_status_str(&st, LT_TAG_DEVICE, "led-talks sample");
	lt_status_u32(&st, LT_TAG_UPTIME, (uint32_t)(k_uptime_get() / 1000));
	lt_status_str(&st, LT_TAG_STATE, "ok");
	return lt_status_len(&st);
}

int main(void)
{
	if (lt_zephyr_init_gpio(&led, PERIOD_US) != 0 || !gpio_is_ready_dt(&button) ||
	    gpio_pin_configure_dt(&button, GPIO_INPUT) != 0) {
		printk("LED or button not ready\n");
		return 0;
	}
	printk("press the button to blink a status report\n");

	for (;;) {
		k_msleep(20);
		if (gpio_pin_get_dt(&button) <= 0 || lt_zephyr_busy()) {
			continue;
		}
		uint8_t buf[LT_MAX_PAYLOAD];
		size_t len = build_status(buf, sizeof(buf));

		if (len == 0 || lt_zephyr_send(buf, len, true) != 0) {
			printk("could not send status\n");
			continue;
		}
		/* Stop in the third frame's gap, so no fourth one begins. */
		int64_t symbols = (int64_t)lt_zephyr_repeat_symbols(len) * REPEATS -
				  LT_ZEPHYR_GAP_SYMBOLS / 2;

		k_msleep((int32_t)(symbols * PERIOD_US / 1000));
		lt_zephyr_stop();

		while (gpio_pin_get_dt(&button) > 0) {
			k_msleep(20); /* wait for release */
		}
	}
}
