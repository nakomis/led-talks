if(CONFIG_LED_TALKS)
	zephyr_library()
	zephyr_library_sources(
		src/led_talks_zephyr.c
		../core/src/led_talks.c
	)
	zephyr_include_directories(include ../core/include)
endif()
