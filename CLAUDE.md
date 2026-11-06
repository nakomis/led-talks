# LED Talks

Devices blink their status LED; an iPhone camera reads it. Plane project: **TALK**.

## Key decisions

- **The protocol is the contract** (`docs/protocol.md`). The C encoder and the Swift decoder are
  written independently and both test against its test vectors; change the spec first.
- **Training sequence in every message:** the decoder learns each symbol's appearance from the
  message itself, so there is no per-LED or per-camera calibration anywhere.
- **Timing is recovered by the decoder** (from the preamble, then from transitions); the device
  just plays symbols at a nominal period. Whitening keeps transitions frequent.
- **Day-one symbol sets:** OOK (on/off), PAM-4 (four brightness levels), and RGB-8 (each channel
  fully on or off, so a WS2812's slow internal PWM never matters). Denser colour sets are
  reserved in the spec, not built.
- **Encoder core is portable C** with no platform code (host-tested with plain C, as in
  iphone-remote). Ports are thin: ESP-IDF (WS2812 via `espressif/led_strip`, or a GPIO) and
  Zephyr (GPIO or PWM).
- **Reader:** a standalone SwiftUI app; the decoder lives in the `LEDTalksKit` Swift package
  (Foundation only, so `swift test` runs anywhere), so ScreenEye can embed it later
  (iphone-remote IREM-7, Plan B pairing).
- No AWS, no deploys. The app runs from Xcode on Martin's phone; no TestFlight yet.

## Repository layout

| Path | What |
|---|---|
| `docs/protocol.md` | The protocol and test vectors |
| `encoder/core/` | Portable C encoder + status builder; `tests/` has the host tests |
| `encoder/esp-idf/` | ESP-IDF component |
| `encoder/zephyr/` | Zephyr module |
| `reader/LEDTalksKit/` | Swift package: decoder, status format, synthetic camera |
| `reader/app/` | iOS app; `xcodegen generate` makes the project (not committed) |

## Testing

- C: `make -C encoder/core/tests test` (and `coverage`); 70% minimum, aim for all of the core.
- ESP-IDF port (build only; v5.5): `. ~/esp/v5.5/esp-idf/export.sh && cd encoder/esp-idf/examples/status && idf.py set-target esp32s3 && idf.py build`.
- Zephyr port (build only; NCS 3.4.2): `source ~/ncs/.venv/bin/activate && cd ~/ncs/v3.4.2 && west build -p --no-sysbuild -b promicro_nrf52840/nrf52840/uf2 -d build/talk3 <repo>/encoder/zephyr/samples/status -- -DEXTRA_ZEPHYR_MODULES=<repo>/encoder/zephyr`.
- Swift: `cd reader/LEDTalksKit && swift test`.
- App: `cd reader/app && xcodegen generate && xcodebuild -scheme LEDTalks -destination 'generic/platform=iOS Simulator' build`.
- Real cameras can only be tested on a phone; the synthetic camera (`SyntheticCamera`) models
  frame rate, exposure, clock skew, noise, gamma, white balance, and colour crosstalk.

## Architecture diagrams

Source: `docs/architecture/led-talks.drawio`; the SVG is auto-regenerated on commit by
`.githooks/pre-commit`.

To activate the hook after cloning:

```bash
git config core.hooksPath .githooks
```
