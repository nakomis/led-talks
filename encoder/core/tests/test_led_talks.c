/* Host tests for the LED Talks encoder against docs/protocol.md §7. Plain C, no framework. */
#include <stdio.h>
#include <string.h>

#include "led_talks.h"

static int failures, checks;

#define CHECK(cond)                                                                                \
	do {                                                                                       \
		checks++;                                                                          \
		if (!(cond)) {                                                                     \
			failures++;                                                                \
			printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                     \
		}                                                                                  \
	} while (0)

/* Symbols as a digit string, without the "|" separators the spec uses. */
static void symbols_str(const uint8_t *s, size_t n, char *out)
{
	for (size_t i = 0; i < n; i++) {
		out[i] = (char)('0' + s[i]);
	}
	out[n] = 0;
}

static void strip(const char *in, char *out)
{
	for (; *in; in++) {
		if (*in != ' ' && *in != '|') {
			*out++ = *in;
		}
	}
	*out = 0;
}

static void check_vector(lt_mode_t mode, const uint8_t *payload, size_t len, const char *spec)
{
	uint8_t sym[1024];
	char got[1024], want[1024];
	size_t n = lt_encode(mode, payload, len, sym, sizeof(sym));

	strip(spec, want);
	symbols_str(sym, n, got);
	CHECK(n == lt_frame_symbols(mode, len));
	CHECK(strcmp(got, want) == 0);
	if (strcmp(got, want) != 0) {
		printf("  mode %d\n  got  %s\n  want %s\n", mode, got, want);
	}
}

static const uint8_t hi[2] = {'H', 'i'};

static void test_crc_and_whitening(void)
{
	CHECK(lt_crc16((const uint8_t *)"123456789", 9) == 0x29B1);
	CHECK(lt_crc16(NULL, 0) == 0xFFFF);

	uint8_t w[8] = {0};
	const uint8_t want[8] = {0xFF, 0x83, 0xDF, 0x17, 0x32, 0x09, 0x4E, 0xD1};

	lt_whiten(w, 8);
	CHECK(memcmp(w, want, 8) == 0);

	uint8_t buf[300], orig[300];

	for (int i = 0; i < 300; i++) {
		buf[i] = orig[i] = (uint8_t)(i * 7);
	}
	lt_whiten(buf, 300);
	CHECK(memcmp(buf, orig, 300) != 0);
	lt_whiten(buf, 300);
	CHECK(memcmp(buf, orig, 300) == 0); /* its own inverse */
}

static void test_vectors(void)
{
	check_vector(LT_MODE_OOK, hi, 2,
		     "101010101010 | 11100100 | 00010001 | 01 | "
		     "1111110111001011101101101110100101101011");
	check_vector(LT_MODE_PAM4, hi, 2,
		     "303030303030 | 33300300 | 00030030 | 0123 | 33313023231213022313");
	check_vector(LT_MODE_RGB8, hi, 2,
		     "707070707070 | 77700700 | 00070077 | 01234567 | 77345666010014");
	check_vector(LT_MODE_OOK, NULL, 0,
		     "101010101010 | 11100100 | 00010001 | 01 | 111111111010111010010010");

	uint8_t buf[64];
	lt_status_t s;

	lt_status_init(&s, buf, sizeof(buf));
	lt_status_str(&s, LT_TAG_DEVICE, "fob");
	lt_status_str(&s, LT_TAG_FIRMWARE, "1.0.0");
	lt_status_u32(&s, LT_TAG_UPTIME, 3600);
	lt_status_u16(&s, LT_TAG_BATTERY_MV, 2950);
	const uint8_t want[] = {0x01, 0x01, 0x03, 0x66, 0x6F, 0x62, 0x02, 0x05, 0x31, 0x2E, 0x30, 0x2E,
				0x30, 0x03, 0x04, 0x10, 0x0E, 0x00, 0x00, 0x04, 0x02, 0x86, 0x0B};

	CHECK(lt_status_len(&s) == sizeof(want));
	CHECK(memcmp(buf, want, sizeof(want)) == 0);
	check_vector(LT_MODE_RGB8, buf, lt_status_len(&s),
		     "707070707070 | 77700700 | 00070077 | 01234567 | "
		     "72101336050521461315174277122241721627076005005706047121410713273"
		     "30124");
}

static void test_modes_and_sizes(void)
{
	CHECK(lt_mode_symbols(LT_MODE_OOK) == 2 && lt_mode_bits(LT_MODE_OOK) == 1);
	CHECK(lt_mode_symbols(LT_MODE_PAM4) == 4 && lt_mode_bits(LT_MODE_PAM4) == 2);
	CHECK(lt_mode_symbols(LT_MODE_RGB8) == 8 && lt_mode_bits(LT_MODE_RGB8) == 3);
	CHECK(lt_mode_symbols((lt_mode_t)9) == 0 && lt_mode_bits((lt_mode_t)9) == 0);

	CHECK(lt_frame_symbols(LT_MODE_OOK, 2) == 70);
	CHECK(lt_frame_symbols(LT_MODE_PAM4, 2) == 52);
	CHECK(lt_frame_symbols(LT_MODE_RGB8, 2) == 50);
	CHECK(lt_frame_symbols(LT_MODE_RGB8, 255) == 28 + 8 + (8 * 258 + 2) / 3);
	CHECK(lt_frame_symbols(LT_MODE_OOK, 256) == 0);
	CHECK(lt_frame_symbols((lt_mode_t)0, 1) == 0);

	uint8_t sym[4096];
	uint8_t big[256] = {0};

	CHECK(lt_encode(LT_MODE_OOK, big, 256, sym, sizeof(sym)) == 0);  /* too long */
	CHECK(lt_encode(LT_MODE_OOK, hi, 2, sym, 69) == 0);              /* no room */
	CHECK(lt_encode(LT_MODE_OOK, NULL, 2, sym, sizeof(sym)) == 0);   /* no payload */
	CHECK(lt_encode((lt_mode_t)7, hi, 2, sym, sizeof(sym)) == 0);    /* unknown mode */
	CHECK(lt_encode(LT_MODE_RGB8, big, 255, sym, sizeof(sym)) ==
	      lt_frame_symbols(LT_MODE_RGB8, 255));

	/* Every symbol is in the alphabet. */
	size_t n = lt_encode(LT_MODE_PAM4, big, 255, sym, sizeof(sym));
	int bad = 0;

	for (size_t i = 0; i < n; i++) {
		bad += sym[i] > 3;
	}
	CHECK(bad == 0);
}

static void test_levels_and_colours(void)
{
	CHECK(lt_level(LT_MODE_OOK, 0) == 0 && lt_level(LT_MODE_OOK, 1) == 255);
	CHECK(lt_level(LT_MODE_PAM4, 0) == 0 && lt_level(LT_MODE_PAM4, 1) == 31);
	CHECK(lt_level(LT_MODE_PAM4, 2) == 102 && lt_level(LT_MODE_PAM4, 3) == 255);
	CHECK(lt_level(LT_MODE_RGB8, 0) == 0 && lt_level(LT_MODE_RGB8, 5) == 255);
	CHECK(lt_level((lt_mode_t)0, 1) == 0);

	lt_rgb_t white = {255, 255, 255}, amber = {255, 128, 0};
	lt_rgb_t c = lt_colour(LT_MODE_RGB8, 4, white);

	CHECK(c.r == 255 && c.g == 0 && c.b == 0);
	c = lt_colour(LT_MODE_RGB8, 3, white);
	CHECK(c.r == 0 && c.g == 255 && c.b == 255);
	c = lt_colour(LT_MODE_RGB8, 0, white);
	CHECK(c.r == 0 && c.g == 0 && c.b == 0);
	c = lt_colour(LT_MODE_OOK, 1, amber);
	CHECK(c.r == 255 && c.g == 128 && c.b == 0);
	c = lt_colour(LT_MODE_PAM4, 2, amber);
	CHECK(c.r == 102 && c.g == 51 && c.b == 0);
	c = lt_colour(LT_MODE_PAM4, 0, amber);
	CHECK(c.r == 0 && c.g == 0 && c.b == 0);
}

static void test_player(void)
{
	const uint8_t msg[3] = {3, 1, 2};
	lt_player_t p;
	int got[16];

	lt_player_start(&p, msg, 3, 0, false); /* the gap is raised to LT_MIN_GAP */
	for (int i = 0; i < 9; i++) {
		got[i] = lt_player_next(&p);
	}
	CHECK(got[0] == 3 && got[1] == 1 && got[2] == 2);
	CHECK(got[3] == 0 && got[4] == 0 && got[5] == 0 && got[6] == 0);
	CHECK(got[7] == -1 && got[8] == -1);

	lt_player_start(&p, msg, 3, 5, true);
	for (int i = 0; i < 16; i++) {
		got[i] = lt_player_next(&p);
	}
	CHECK(got[3] == 0 && got[7] == 0); /* five off symbols */
	CHECK(got[8] == 3 && got[9] == 1 && got[10] == 2 && got[11] == 0);

	lt_player_stop(&p);
	CHECK(lt_player_next(&p) == -1);
}

static void test_status_builder(void)
{
	uint8_t buf[300];
	lt_status_t s;

	lt_status_init(&s, buf, 0);
	CHECK(lt_status_len(&s) == 0); /* no room for the content type */

	lt_status_init(&s, buf, 6);
	lt_status_u16(&s, LT_TAG_ERROR, 0x1234);
	CHECK(lt_status_len(&s) == 5 && buf[3] == 0x34 && buf[4] == 0x12);
	lt_status_u16(&s, LT_TAG_ERROR, 1); /* doesn't fit */
	CHECK(lt_status_len(&s) == 0);
	lt_status_str(&s, LT_TAG_STATE, ""); /* stays overflowed */
	CHECK(lt_status_len(&s) == 0);

	lt_status_init(&s, buf, sizeof(buf));
	lt_status_i16(&s, LT_TAG_TEMP_CENTI_C, -150);
	CHECK(buf[3] == 0x6A && buf[4] == 0xFF);
	lt_status_bytes(&s, LT_TAG_ID, NULL, 0);
	CHECK(lt_status_len(&s) == 7 && buf[5] == LT_TAG_ID && buf[6] == 0);

	/* Never more than LT_MAX_PAYLOAD, however big the buffer. */
	char long_str[300];

	memset(long_str, 'x', sizeof(long_str) - 1);
	long_str[sizeof(long_str) - 1] = 0;
	lt_status_init(&s, buf, sizeof(buf));
	lt_status_str(&s, LT_TAG_KV, long_str); /* truncated to 255, but 1 + 2 + 255 > 255 */
	CHECK(lt_status_len(&s) == 0);
	lt_status_init(&s, buf, sizeof(buf));
	lt_status_bytes(&s, LT_TAG_KV, long_str, 256);
	CHECK(lt_status_len(&s) == 0);
	lt_status_init(&s, buf, sizeof(buf));
	lt_status_bytes(&s, LT_TAG_KV, long_str, 252); /* exactly 255 */
	CHECK(lt_status_len(&s) == 255);
}

int main(void)
{
	test_crc_and_whitening();
	test_vectors();
	test_modes_and_sizes();
	test_levels_and_colours();
	test_player();
	test_status_builder();
	printf("%d checks, %d failures\n", checks, failures);
	return failures ? 1 : 0;
}
