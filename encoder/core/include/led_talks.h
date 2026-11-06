/* LED Talks encoder (docs/protocol.md). Portable C: no platform code, no allocation.
 *
 * A message is a sequence of symbols. A port shows one symbol per symbol period on its LED:
 * lt_level() for a single LED, lt_colour() for an RGB one. lt_player_t steps through a message
 * for a port's timer callback. lt_status_t builds the usual payload, a status report. */
#ifndef LED_TALKS_H
#define LED_TALKS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LT_VERSION 1
#define LT_MAX_PAYLOAD 255

/* Section numbers refer to docs/protocol.md. */
typedef enum {
	LT_MODE_OOK = 1,  /* off/on: 1 bit per symbol */
	LT_MODE_PAM4 = 2, /* four brightness levels: 2 bits per symbol */
	LT_MODE_RGB8 = 3, /* eight colours, each channel off or full: 3 bits per symbol */
} lt_mode_t;

typedef struct {
	uint8_t r, g, b;
} lt_rgb_t;

/* Symbols in the mode's alphabet (2, 4 or 8), or 0 for an unknown mode. */
unsigned lt_mode_symbols(lt_mode_t mode);
/* Data bits per symbol (1, 2 or 3), or 0 for an unknown mode. */
unsigned lt_mode_bits(lt_mode_t mode);

/* Symbols in the frame for a payload of len bytes (§3), or 0 if the mode or length is invalid. */
size_t lt_frame_symbols(lt_mode_t mode, size_t len);

/* Encodes a frame (§3) into out, one symbol (0..N-1) per byte. Returns the number of symbols,
 * or 0 if the mode is unknown, len > LT_MAX_PAYLOAD, or cap is too small. */
size_t lt_encode(lt_mode_t mode, const uint8_t *payload, size_t len, uint8_t *out, size_t cap);

/* A symbol's brightness for a single-colour LED, 0-255, linear (PWM duty) (§2). For RGB-8 it's
 * the brightness of "any channel on", which suits nothing: use lt_colour() for RGB LEDs. */
uint8_t lt_level(lt_mode_t mode, uint8_t symbol);

/* A symbol's colour for an RGB LED (§2). OOK and PAM-4 scale `on` by lt_level(); RGB-8 ignores
 * `on` and uses its own palette. */
lt_rgb_t lt_colour(lt_mode_t mode, uint8_t symbol, lt_rgb_t on);

/* CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR (§3.5). */
uint16_t lt_crc16(const uint8_t *data, size_t len);

/* XORs buf with the whitening sequence from its start (§3.6). Its own inverse. */
void lt_whiten(uint8_t *buf, size_t len);

/* Plays a message: call lt_player_next() once per symbol period and show what it returns. */
typedef struct {
	const uint8_t *symbols;
	size_t count;
	size_t pos;
	unsigned gap;      /* off symbols between repeats */
	unsigned gap_left;
	bool repeat;
} lt_player_t;

/* gap_symbols is clamped up to LT_MIN_GAP (§3.8). */
#define LT_MIN_GAP 4
void lt_player_start(lt_player_t *p, const uint8_t *symbols, size_t count, unsigned gap_symbols,
		     bool repeat);
/* The symbol to show now (symbol 0, off, during gaps), or -1 once a non-repeating message has
 * finished, including its trailing gap. */
int lt_player_next(lt_player_t *p);
/* Stops at once: lt_player_next() returns -1 from now on. */
void lt_player_stop(lt_player_t *p);

/* Status report (§4): a content-type byte, then type-length-value fields. */
enum {
	LT_CONTENT_RAW = 0x00,
	LT_CONTENT_STATUS = 0x01,

	LT_TAG_DEVICE = 0x01,      /* UTF-8 */
	LT_TAG_FIRMWARE = 0x02,    /* UTF-8 */
	LT_TAG_UPTIME = 0x03,      /* u32 LE, seconds */
	LT_TAG_BATTERY_MV = 0x04,  /* u16 LE, millivolts */
	LT_TAG_STATE = 0x05,       /* UTF-8 */
	LT_TAG_ERROR = 0x06,       /* u16 LE */
	LT_TAG_ID = 0x07,          /* bytes, shown as hex */
	LT_TAG_KV = 0x08,          /* UTF-8 "key=value", repeatable */
	LT_TAG_TEMP_CENTI_C = 0x09,/* i16 LE, hundredths of a degree Celsius */
	LT_TAG_DEVICE_SPECIFIC = 0x80, /* 0x80-0xFF: the device's own, shown as hex */
};

typedef struct {
	uint8_t *buf;
	size_t cap;
	size_t len;
	bool overflow;
} lt_status_t;

/* Starts a status report in buf (writes the content-type byte). */
void lt_status_init(lt_status_t *s, uint8_t *buf, size_t cap);
void lt_status_bytes(lt_status_t *s, uint8_t tag, const void *value, size_t len);
/* A string is truncated to 255 bytes. */
void lt_status_str(lt_status_t *s, uint8_t tag, const char *value);
void lt_status_u16(lt_status_t *s, uint8_t tag, uint16_t value);
void lt_status_u32(lt_status_t *s, uint8_t tag, uint32_t value);
void lt_status_i16(lt_status_t *s, uint8_t tag, int16_t value);
/* The report's length, or 0 if it didn't fit in buf or LT_MAX_PAYLOAD. */
size_t lt_status_len(const lt_status_t *s);

#ifdef __cplusplus
}
#endif

#endif /* LED_TALKS_H */
