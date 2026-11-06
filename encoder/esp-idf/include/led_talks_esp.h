/* LED Talks on ESP-IDF: plays an encoded message on a WS2812, a plain GPIO LED, or an LEDC-PWM
 * LED, one symbol per period, from an esp_timer. Call everything from task context. */
#ifndef LED_TALKS_ESP_H
#define LED_TALKS_ESP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "led_talks.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	LT_ESP_LED_WS2812, /* via espressif/led_strip (RMT); OOK, PAM-4 and RGB-8 */
	LT_ESP_LED_GPIO,   /* plain on/off; OOK only */
	LT_ESP_LED_LEDC,   /* PWM brightness; OOK and PAM-4 */
} lt_esp_led_t;

typedef struct {
	lt_esp_led_t led;
	int gpio;
	lt_mode_t mode;
	uint32_t period_us; /* symbol period T; 0 means 33333 (30 symbols a second) */
	lt_rgb_t on;        /* WS2812 "on" colour for OOK and PAM-4 (RGB-8 has its own palette) */
	bool active_low;    /* GPIO and LEDC: LED lit by driving the pin low */
	uint32_t ledc_freq_hz; /* LEDC: 0 means 20000; must be at least 10000 (protocol §2) */
} lt_esp_config_t;

/* WS2812 on the given pin, RGB-8, 33.3 ms symbols, white for "on". */
#define LT_ESP_CONFIG_WS2812(pin) \
	{ .led = LT_ESP_LED_WS2812, .gpio = (pin), .mode = LT_MODE_RGB8, .period_us = 33333, \
	  .on = { 255, 255, 255 } }

/* Off symbols between repeats (and after a single send); at least LT_MIN_GAP. */
#define LT_ESP_GAP_SYMBOLS 8

/* Longest frame, in symbols: 255 bytes in OOK (see lt_frame_symbols()). */
#define LT_ESP_MAX_SYMBOLS 2100

/* Sets up the LED and the timer. ESP_ERR_INVALID_ARG if the mode doesn't suit the LED (GPIO
 * is OOK only, LEDC is OOK or PAM-4, RGB-8 needs a WS2812) or a value is out of range. Call once. */
esp_err_t lt_esp_init(const lt_esp_config_t *cfg);

/* Encodes payload and starts playing it, replacing any message in progress. With repeat it
 * loops, separated by a gap, until lt_esp_stop(). ESP_ERR_INVALID_SIZE if it doesn't encode,
 * ESP_ERR_INVALID_STATE before lt_esp_init(). The payload is encoded at once, not kept. */
esp_err_t lt_esp_send(const uint8_t *payload, size_t len, bool repeat);

/* Stops at once and turns the LED off. */
void lt_esp_stop(void);

/* True while a message is playing (always, if repeating). */
bool lt_esp_busy(void);

/* Symbols in one repeat of a payload (frame plus gap), for timing a stop; 0 if invalid. */
size_t lt_esp_repeat_symbols(size_t len);

#ifdef __cplusplus
}
#endif

#endif /* LED_TALKS_ESP_H */
