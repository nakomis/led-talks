/* LED Talks ESP-IDF port. */
#include "led_talks_esp.h"

#include <string.h>

#include "driver/gpio.h"
#include "driver/ledc.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "led_strip.h"

#define DEFAULT_PERIOD_US 33333
#define DEFAULT_LEDC_HZ 20000
#define MIN_LEDC_HZ 10000 /* §2: fast enough that no camera exposure sees the PWM */

static struct {
	bool ready;
	lt_esp_config_t cfg;
	led_strip_handle_t strip;
	esp_timer_handle_t timer;
	/* out serialises "pick a symbol and show it" against stop(), so a tick that is already
	 * running can't light the LED after stop() has turned it off. lock guards the player. */
	SemaphoreHandle_t out;
	portMUX_TYPE lock;
	lt_player_t player;
	bool playing;
	uint8_t symbols[LT_ESP_MAX_SYMBOLS];
} s = { .lock = portMUX_INITIALIZER_UNLOCKED };

static void show(int symbol)
{
	/* symbol < 0 is "off": the end of a message, or stop. */
	uint8_t sym = symbol < 0 ? 0 : (uint8_t)symbol;

	if (s.cfg.led == LT_ESP_LED_WS2812) {
		lt_rgb_t c = symbol < 0 ? (lt_rgb_t){ 0, 0, 0 } :
					  lt_colour(s.cfg.mode, sym, s.cfg.on);

		led_strip_set_pixel(s.strip, 0, c.r, c.g, c.b);
		led_strip_refresh(s.strip);
		return;
	}
	uint8_t level = symbol < 0 ? 0 : lt_level(s.cfg.mode, sym);

	if (s.cfg.led == LT_ESP_LED_GPIO) {
		gpio_set_level(s.cfg.gpio, (level != 0) != s.cfg.active_low);
		return;
	}
	/* LEDC is 8-bit, matching lt_level(), so the level is the duty. */
	uint32_t duty = s.cfg.active_low ? 255 - level : level;

	ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, duty);
	ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
}

/* Runs in the esp_timer task, not an ISR: led_strip_refresh() blocks on the RMT. The task's
 * wake-up jitter is well inside T/10 (3.3 ms at the default period) unless higher-priority
 * work hogs the CPU. */
static void tick(void *arg)
{
	(void)arg;
	xSemaphoreTake(s.out, portMAX_DELAY);
	portENTER_CRITICAL(&s.lock);
	int symbol = s.playing ? lt_player_next(&s.player) : -1;

	if (symbol < 0) {
		s.playing = false;
	}
	portEXIT_CRITICAL(&s.lock);

	show(symbol);
	if (symbol < 0) {
		esp_timer_stop(s.timer);
	}
	xSemaphoreGive(s.out);
}

esp_err_t lt_esp_init(const lt_esp_config_t *cfg)
{
	if (cfg == NULL) {
		return ESP_ERR_INVALID_ARG;
	}
	if (s.ready) {
		return ESP_ERR_INVALID_STATE;
	}
	if (lt_mode_symbols(cfg->mode) == 0) {
		return ESP_ERR_INVALID_ARG;
	}
	bool mode_ok = cfg->led == LT_ESP_LED_WS2812 ||
		       (cfg->led == LT_ESP_LED_GPIO && cfg->mode == LT_MODE_OOK) ||
		       (cfg->led == LT_ESP_LED_LEDC && cfg->mode != LT_MODE_RGB8);

	if (!mode_ok || cfg->gpio < 0 ||
	    (cfg->ledc_freq_hz != 0 && cfg->ledc_freq_hz < MIN_LEDC_HZ)) {
		return ESP_ERR_INVALID_ARG;
	}

	s.cfg = *cfg;
	if (s.cfg.period_us == 0) {
		s.cfg.period_us = DEFAULT_PERIOD_US;
	}
	if (s.cfg.ledc_freq_hz == 0) {
		s.cfg.ledc_freq_hz = DEFAULT_LEDC_HZ;
	}

	esp_err_t err = ESP_OK;

	switch (s.cfg.led) {
	case LT_ESP_LED_WS2812: {
		led_strip_config_t strip_cfg = {
			.strip_gpio_num = s.cfg.gpio,
			.max_leds = 1,
			.led_model = LED_MODEL_WS2812,
			.color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB,
		};
		led_strip_rmt_config_t rmt_cfg = {
			.clk_src = RMT_CLK_SRC_DEFAULT,
			.resolution_hz = 10 * 1000 * 1000,
		};

		err = led_strip_new_rmt_device(&strip_cfg, &rmt_cfg, &s.strip);
		break;
	}
	case LT_ESP_LED_GPIO:
		err = gpio_reset_pin(s.cfg.gpio);
		if (err == ESP_OK) {
			err = gpio_set_direction(s.cfg.gpio, GPIO_MODE_OUTPUT);
		}
		break;
	case LT_ESP_LED_LEDC: {
		ledc_timer_config_t t = {
			.speed_mode = LEDC_LOW_SPEED_MODE,
			.duty_resolution = LEDC_TIMER_8_BIT,
			.timer_num = LEDC_TIMER_0,
			.freq_hz = s.cfg.ledc_freq_hz,
			.clk_cfg = LEDC_AUTO_CLK,
		};
		ledc_channel_config_t ch = {
			.gpio_num = s.cfg.gpio,
			.speed_mode = LEDC_LOW_SPEED_MODE,
			.channel = LEDC_CHANNEL_0,
			.timer_sel = LEDC_TIMER_0,
			.duty = s.cfg.active_low ? 255 : 0,
		};

		err = ledc_timer_config(&t);
		if (err == ESP_OK) {
			err = ledc_channel_config(&ch);
		}
		break;
	}
	}
	if (err != ESP_OK) {
		return err;
	}

	s.out = xSemaphoreCreateMutex();
	if (s.out == NULL) {
		return ESP_ERR_NO_MEM;
	}
	const esp_timer_create_args_t args = { .callback = tick, .name = "led_talks" };

	err = esp_timer_create(&args, &s.timer);
	if (err != ESP_OK) {
		return err;
	}
	s.ready = true;
	show(-1);
	return ESP_OK;
}

void lt_esp_stop(void)
{
	if (!s.ready) {
		return;
	}
	xSemaphoreTake(s.out, portMAX_DELAY);
	portENTER_CRITICAL(&s.lock);
	lt_player_stop(&s.player);
	s.playing = false;
	portEXIT_CRITICAL(&s.lock);

	esp_timer_stop(s.timer); /* ESP_ERR_INVALID_STATE if not running: fine */
	show(-1);
	xSemaphoreGive(s.out);
}

esp_err_t lt_esp_send(const uint8_t *payload, size_t len, bool repeat)
{
	if (!s.ready) {
		return ESP_ERR_INVALID_STATE;
	}
	if (payload == NULL && len > 0) {
		return ESP_ERR_INVALID_ARG;
	}
	lt_esp_stop();

	/* The player is stopped, so tick() never reads symbols[] while it is rewritten. */
	size_t n = lt_encode(s.cfg.mode, payload, len, s.symbols, sizeof(s.symbols));

	if (n == 0) {
		return ESP_ERR_INVALID_SIZE;
	}
	portENTER_CRITICAL(&s.lock);
	lt_player_start(&s.player, s.symbols, n, LT_ESP_GAP_SYMBOLS, repeat);
	s.playing = true;
	portEXIT_CRITICAL(&s.lock);

	/* The first symbol appears one period after this call; the decoder doesn't care. */
	return esp_timer_start_periodic(s.timer, s.cfg.period_us);
}

bool lt_esp_busy(void)
{
	portENTER_CRITICAL(&s.lock);
	bool busy = s.playing;

	portEXIT_CRITICAL(&s.lock);
	return busy;
}

size_t lt_esp_repeat_symbols(size_t len)
{
	size_t n = lt_frame_symbols(s.cfg.mode, len);

	return n == 0 ? 0 : n + LT_ESP_GAP_SYMBOLS;
}
