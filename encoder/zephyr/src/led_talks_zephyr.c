/* LED Talks Zephyr port. */
#include "led_talks_zephyr.h"

#include <errno.h>

#include <zephyr/kernel.h>

#define MAX_PWM_PERIOD_NS 100000 /* §2: 10 kHz or faster */

static struct {
	bool ready;
	bool pwm;
	const struct gpio_dt_spec *gpio;
#ifdef CONFIG_LED_TALKS_PWM
	const struct pwm_dt_spec *pwm_led;
#endif
	lt_mode_t mode;
	uint32_t period_us;
	struct k_timer timer;
	/* The lock covers the player and the LED, so a tick that is already running can't
	 * light the LED after lt_zephyr_stop() has turned it off. */
	struct k_spinlock lock;
	lt_player_t player;
	bool playing;
	uint8_t symbols[LT_ZEPHYR_MAX_SYMBOLS];
} s;

/* Called with the lock held, and from the timer's ISR: keep it short. */
static void show(int symbol)
{
	uint8_t level = symbol < 0 ? 0 : lt_level(s.mode, (uint8_t)symbol);

	if (!s.pwm) {
		gpio_pin_set_dt(s.gpio, level != 0);
		return;
	}
#ifdef CONFIG_LED_TALKS_PWM
	/* lt_level() is linear duty, 0-255. */
	uint32_t period = s.pwm_led->period;

	pwm_set_dt(s.pwm_led, period, (uint32_t)(((uint64_t)period * level) / 255));
#endif
}

static void tick(struct k_timer *timer)
{
	k_spinlock_key_t key = k_spin_lock(&s.lock);
	int symbol = s.playing ? lt_player_next(&s.player) : -1;

	if (symbol < 0) {
		s.playing = false;
		k_timer_stop(timer);
	}
	show(symbol);
	k_spin_unlock(&s.lock, key);
}

static int init_common(lt_mode_t mode, uint32_t period_us)
{
	if (s.ready) {
		return -EALREADY;
	}
	s.mode = mode;
	s.period_us = period_us ? period_us : LT_ZEPHYR_DEFAULT_PERIOD_US;
	k_timer_init(&s.timer, tick, NULL);
	return 0;
}

int lt_zephyr_init_gpio(const struct gpio_dt_spec *led, uint32_t period_us)
{
	if (led == NULL) {
		return -EINVAL;
	}
	if (!gpio_is_ready_dt(led)) {
		return -ENODEV;
	}
	int ret = init_common(LT_MODE_OOK, period_us);

	if (ret == 0) {
		ret = gpio_pin_configure_dt(led, GPIO_OUTPUT_INACTIVE);
	}
	if (ret == 0) {
		s.pwm = false;
		s.gpio = led;
		s.ready = true;
	}
	return ret;
}

#ifdef CONFIG_LED_TALKS_PWM
int lt_zephyr_init_pwm(const struct pwm_dt_spec *led, lt_mode_t mode, uint32_t period_us)
{
	if (led == NULL || (mode != LT_MODE_OOK && mode != LT_MODE_PAM4) ||
	    led->period == 0 || led->period > MAX_PWM_PERIOD_NS) {
		return -EINVAL;
	}
	if (!pwm_is_ready_dt(led)) {
		return -ENODEV;
	}
	int ret = init_common(mode, period_us);

	if (ret == 0) {
		s.pwm = true;
		s.pwm_led = led;
		s.ready = true;
		K_SPINLOCK(&s.lock) {
			show(-1);
		}
	}
	return ret;
}
#endif

void lt_zephyr_stop(void)
{
	if (!s.ready) {
		return;
	}
	K_SPINLOCK(&s.lock) {
		lt_player_stop(&s.player);
		s.playing = false;
		k_timer_stop(&s.timer);
		show(-1);
	}
}

int lt_zephyr_send(const uint8_t *payload, size_t len, bool repeat)
{
	if (!s.ready) {
		return -ENODEV;
	}
	if (payload == NULL && len > 0) {
		return -EINVAL;
	}
	lt_zephyr_stop();

	/* Two threads sending at once would trample the buffer; callers serialise their sends. */
	size_t n = lt_encode(s.mode, payload, len, s.symbols, sizeof(s.symbols));

	if (n == 0) {
		return -EMSGSIZE;
	}
	K_SPINLOCK(&s.lock) {
		lt_player_start(&s.player, s.symbols, n, LT_ZEPHYR_GAP_SYMBOLS, repeat);
		s.playing = true;
		/* The first symbol appears one period from now; the decoder doesn't care. */
		k_timer_start(&s.timer, K_USEC(s.period_us), K_USEC(s.period_us));
	}
	return 0;
}

bool lt_zephyr_busy(void)
{
	bool busy;

	K_SPINLOCK(&s.lock) {
		busy = s.playing;
	}
	return busy;
}

size_t lt_zephyr_repeat_symbols(size_t len)
{
	size_t n = lt_frame_symbols(s.mode, len);

	return n == 0 ? 0 : n + LT_ZEPHYR_GAP_SYMBOLS;
}
