idf_component_register(
	SRCS "src/led_talks_esp.c" "../core/src/led_talks.c"
	INCLUDE_DIRS "include" "../core/include"
	REQUIRES esp_timer
	PRIV_REQUIRES esp_driver_gpio esp_driver_ledc
)
