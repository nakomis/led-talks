/* LED Talks encoder (docs/protocol.md). */
#include "led_talks.h"

#include <string.h>

#define PREAMBLE_SYMBOLS 12
#define SYNC_BYTE 0xE4
#define FIXED_SYMBOLS (PREAMBLE_SYMBOLS + 8 + 8) /* preamble, sync, header */

/* §2: PAM-4 drive levels, chosen so a camera's gamma (about 2.2) spaces them roughly evenly. */
static const uint8_t pam4_levels[4] = {0, 31, 102, 255};

unsigned lt_mode_symbols(lt_mode_t mode)
{
	switch (mode) {
	case LT_MODE_OOK:
		return 2;
	case LT_MODE_PAM4:
		return 4;
	case LT_MODE_RGB8:
		return 8;
	}
	return 0;
}

unsigned lt_mode_bits(lt_mode_t mode)
{
	switch (mode) {
	case LT_MODE_OOK:
		return 1;
	case LT_MODE_PAM4:
		return 2;
	case LT_MODE_RGB8:
		return 3;
	}
	return 0;
}

size_t lt_frame_symbols(lt_mode_t mode, size_t len)
{
	unsigned k = lt_mode_bits(mode);

	if (k == 0 || len > LT_MAX_PAYLOAD) {
		return 0;
	}
	size_t body_bits = 8 * (len + 3); /* length, payload, CRC */

	return FIXED_SYMBOLS + lt_mode_symbols(mode) + (body_bits + k - 1) / k;
}

uint16_t lt_crc16(const uint8_t *data, size_t len)
{
	uint16_t crc = 0xFFFF;

	for (size_t i = 0; i < len; i++) {
		crc ^= (uint16_t)data[i] << 8;
		for (int b = 0; b < 8; b++) {
			crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
		}
	}
	return crc;
}

void lt_whiten(uint8_t *buf, size_t len)
{
	uint16_t state = 0x1FF; /* PRBS9, x^9 + x^5 + 1 */

	for (size_t i = 0; i < len; i++) {
		uint8_t w = 0;

		for (int b = 0; b < 8; b++) {
			uint16_t out = (state >> 8) & 1;
			uint16_t fb = ((state >> 8) ^ (state >> 4)) & 1;

			state = (uint16_t)(((state << 1) | fb) & 0x1FF);
			w = (uint8_t)((w << 1) | out);
		}
		buf[i] ^= w;
	}
}

/* Writes a byte as eight binary symbols, MSB first, using the mode's lowest and highest. */
static uint8_t *put_binary(uint8_t *o, uint8_t byte, uint8_t hi)
{
	for (int b = 7; b >= 0; b--) {
		*o++ = (byte >> b) & 1 ? hi : 0;
	}
	return o;
}

size_t lt_encode(lt_mode_t mode, const uint8_t *payload, size_t len, uint8_t *out, size_t cap)
{
	size_t total = lt_frame_symbols(mode, len);

	if (total == 0 || total > cap || (len > 0 && payload == NULL)) {
		return 0;
	}
	unsigned n = lt_mode_symbols(mode), k = lt_mode_bits(mode);
	uint8_t hi = (uint8_t)(n - 1);
	uint8_t header = (uint8_t)(LT_VERSION << 4 | mode);
	uint8_t *o = out;

	for (int i = 0; i < PREAMBLE_SYMBOLS; i++) {
		*o++ = i % 2 == 0 ? hi : 0;
	}
	o = put_binary(o, SYNC_BYTE, hi);
	o = put_binary(o, header, hi);
	for (unsigned s = 0; s < n; s++) {
		*o++ = (uint8_t)s;
	}

	/* Body: length, payload, CRC (over header, length and payload), then whitened. */
	uint8_t body[LT_MAX_PAYLOAD + 3];
	uint8_t crc_in[LT_MAX_PAYLOAD + 2];

	body[0] = (uint8_t)len;
	if (len > 0) {
		memcpy(&body[1], payload, len);
	}
	crc_in[0] = header;
	memcpy(&crc_in[1], body, len + 1);
	uint16_t crc = lt_crc16(crc_in, len + 2);

	body[len + 1] = (uint8_t)(crc >> 8);
	body[len + 2] = (uint8_t)crc;
	lt_whiten(body, len + 3);

	/* MSB first, k bits per symbol, the last padded with zeros. */
	uint32_t acc = 0;
	unsigned have = 0;

	for (size_t i = 0; i < len + 3; i++) {
		acc = (acc << 8) | body[i];
		have += 8;
		while (have >= k) {
			have -= k;
			*o++ = (uint8_t)((acc >> have) & ((1u << k) - 1));
		}
	}
	if (have > 0) {
		*o++ = (uint8_t)((acc << (k - have)) & ((1u << k) - 1));
	}
	return (size_t)(o - out);
}

uint8_t lt_level(lt_mode_t mode, uint8_t symbol)
{
	switch (mode) {
	case LT_MODE_OOK:
		return symbol ? 255 : 0;
	case LT_MODE_PAM4:
		return pam4_levels[symbol & 3];
	case LT_MODE_RGB8:
		return (symbol & 7) ? 255 : 0;
	}
	return 0;
}

static uint8_t scale(uint8_t c, uint8_t level)
{
	return (uint8_t)((c * level + 127) / 255);
}

lt_rgb_t lt_colour(lt_mode_t mode, uint8_t symbol, lt_rgb_t on)
{
	if (mode == LT_MODE_RGB8) {
		return (lt_rgb_t){
			.r = symbol & 4 ? 255 : 0,
			.g = symbol & 2 ? 255 : 0,
			.b = symbol & 1 ? 255 : 0,
		};
	}
	uint8_t l = lt_level(mode, symbol);

	return (lt_rgb_t){.r = scale(on.r, l), .g = scale(on.g, l), .b = scale(on.b, l)};
}

void lt_player_start(lt_player_t *p, const uint8_t *symbols, size_t count, unsigned gap_symbols,
		     bool repeat)
{
	p->symbols = symbols;
	p->count = count;
	p->pos = 0;
	p->gap = gap_symbols < LT_MIN_GAP ? LT_MIN_GAP : gap_symbols;
	p->gap_left = 0;
	p->repeat = repeat;
}

int lt_player_next(lt_player_t *p)
{
	if (p->symbols == NULL) {
		return -1;
	}
	if (p->pos < p->count) {
		int s = p->symbols[p->pos++];

		if (p->pos == p->count) {
			p->gap_left = p->gap;
		}
		return s;
	}
	if (p->gap_left > 0) {
		p->gap_left--;
		if (p->gap_left == 0 && p->repeat) {
			p->pos = 0;
		}
		return 0;
	}
	p->symbols = NULL;
	return -1;
}

void lt_player_stop(lt_player_t *p)
{
	p->symbols = NULL;
}

void lt_status_init(lt_status_t *s, uint8_t *buf, size_t cap)
{
	s->buf = buf;
	s->cap = cap;
	s->len = 0;
	s->overflow = cap < 1;
	if (!s->overflow) {
		buf[s->len++] = LT_CONTENT_STATUS;
	}
}

void lt_status_bytes(lt_status_t *s, uint8_t tag, const void *value, size_t len)
{
	if (s->overflow || len > 255 || s->len + 2 + len > s->cap ||
	    s->len + 2 + len > LT_MAX_PAYLOAD) {
		s->overflow = true;
		return;
	}
	s->buf[s->len++] = tag;
	s->buf[s->len++] = (uint8_t)len;
	if (len > 0) {
		memcpy(&s->buf[s->len], value, len);
	}
	s->len += len;
}

void lt_status_str(lt_status_t *s, uint8_t tag, const char *value)
{
	size_t len = strlen(value);

	lt_status_bytes(s, tag, value, len > 255 ? 255 : len);
}

void lt_status_u16(lt_status_t *s, uint8_t tag, uint16_t value)
{
	uint8_t b[2] = {(uint8_t)value, (uint8_t)(value >> 8)};

	lt_status_bytes(s, tag, b, 2);
}

void lt_status_u32(lt_status_t *s, uint8_t tag, uint32_t value)
{
	uint8_t b[4] = {(uint8_t)value, (uint8_t)(value >> 8), (uint8_t)(value >> 16),
			(uint8_t)(value >> 24)};

	lt_status_bytes(s, tag, b, 4);
}

void lt_status_i16(lt_status_t *s, uint8_t tag, int16_t value)
{
	lt_status_u16(s, tag, (uint16_t)value);
}

size_t lt_status_len(const lt_status_t *s)
{
	return s->overflow ? 0 : s->len;
}
