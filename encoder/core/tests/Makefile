# Host tests for the encoder core: `make -C encoder/core/tests` (needs cc; gcov for coverage).
CFLAGS = -std=c11 -Wall -Wextra -Werror -O0 -g --coverage -I../include

test: test_led_talks
	./test_led_talks

test_led_talks: test_led_talks.c ../src/led_talks.c ../include/led_talks.h
	$(CC) $(CFLAGS) -o $@ test_led_talks.c ../src/led_talks.c

# GNU gcov can exit non-zero after writing its report; the report is what matters.
coverage: test
	-gcov -o . test_led_talks-led_talks.gcda ../src/led_talks.c 2>/dev/null

clean:
	rm -f test_led_talks *.gcda *.gcno *.gcov

.PHONY: test coverage clean
