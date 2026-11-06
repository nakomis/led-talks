idf_component_register(
	SRCS "main.c"
	REQUIRES esp-idf
	PRIV_REQUIRES esp_app_format esp_driver_gpio esp_timer esp_system
)
