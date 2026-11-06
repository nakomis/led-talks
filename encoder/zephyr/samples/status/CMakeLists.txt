cmake_minimum_required(VERSION 3.20.0)

# Build with -DEXTRA_ZEPHYR_MODULES=<repo>/encoder/zephyr to find the led_talks module.
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(led_talks_status)

target_sources(app PRIVATE src/main.c)
