/* Press BOOT: blink a status report on the WS2812, three times, in RGB-8. */
#include <stdio.h>

#include "driver/gpio.h"
#include "esp_app_desc.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "led_talks_esp.h"

#define LED_GPIO 17    /* tinycrypt's key board */
#define BUTTON_GPIO 0  /* BOOT, active low */
#define REPEATS 3

static const char *TAG = "led_talks_status";

static size_t build_status(uint8_t *buf, size_t cap)
{
	lt_status_t st;
	char kv[32];

	lt_status_init(&st, buf, cap);
	lt_status_str(&st, LT_TAG_DEVICE, "led-talks example");
	lt_status_str(&st, LT_TAG_FIRMWARE, esp_app_get_description()->version);
	lt_status_u32(&st, LT_TAG_UPTIME, (uint32_t)(esp_timer_get_time() / 1000000));
	snprintf(kv, sizeof(kv), "heap=%u", (unsigned)esp_get_free_heap_size());
	lt_status_str(&st, LT_TAG_KV, kv);
	return lt_status_len(&st);
}

void app_main(void)
{
	lt_esp_config_t cfg = LT_ESP_CONFIG_WS2812(LED_GPIO);

	ESP_ERROR_CHECK(lt_esp_init(&cfg));

	gpio_config_t btn = {
		.pin_bit_mask = 1ULL << BUTTON_GPIO,
		.mode = GPIO_MODE_INPUT,
		.pull_up_en = GPIO_PULLUP_ENABLE,
	};

	ESP_ERROR_CHECK(gpio_config(&btn));
	ESP_LOGI(TAG, "press BOOT to blink a status report");

	for (;;) {
		vTaskDelay(pdMS_TO_TICKS(20));
		if (gpio_get_level(BUTTON_GPIO) != 0 || lt_esp_busy()) {
			continue;
		}
		uint8_t buf[LT_MAX_PAYLOAD];
		size_t len = build_status(buf, sizeof(buf));

		if (len == 0 || lt_esp_send(buf, len, true) != ESP_OK) {
			ESP_LOGE(TAG, "could not send status");
			continue;
		}
		/* Stop just after the third frame ends, in its gap, so no fourth one begins. */
		uint64_t symbols = (uint64_t)lt_esp_repeat_symbols(len) * REPEATS - LT_ESP_GAP_SYMBOLS / 2;

		ESP_LOGI(TAG, "sending %u bytes, %d times", (unsigned)len, REPEATS);
		vTaskDelay(pdMS_TO_TICKS(symbols * cfg.period_us / 1000));
		lt_esp_stop();

		while (gpio_get_level(BUTTON_GPIO) == 0) {
			vTaskDelay(pdMS_TO_TICKS(20)); /* wait for release */
		}
	}
}
