# LED Talks protocol, version 1

- **Plane:** TALK-1
- **Status:** draft for version 1, 6 November 2026. Proven only against the synthetic camera
  so far; §8 lists what a real phone must confirm.
- **Implementations:** `encoder/core/` (C, TALK-2) and `reader/LEDTalksKit/` (Swift, TALK-4).
  They're written independently, and both test against §7's test vectors.

A device shows a message on an LED as a sequence of **symbols**, one per **symbol period**. A
camera films the LED, and a decoder turns the frames back into the message.

The design rests on three ideas:

- **The decoder learns the symbols from the message.** Every message carries a training
  sequence, each symbol once in a known order, so the decoder needs no calibration for the LED,
  the camera, the distance, or the room.
- **The decoder recovers the timing.** The device plays symbols at a nominal period on its own
  clock. The decoder measures the period from the preamble, then tracks it on the transitions.
- **The body is whitened,** so transitions stay frequent whatever the payload.

## 1. Conventions

- Bytes become symbols most significant bit first.
- Multi-byte fields in the frame are big-endian (the CRC). Multi-byte fields in a status report
  are little-endian (§4).
- "HI" is a mode's highest symbol (N − 1), and "LO" is symbol 0, which is always off/black.

## 2. Modes

| Mode | Value | Symbols (N) | Bits per symbol (k) | Suits |
|---|---|---|---|---|
| OOK | 1 | 2 | 1 | Any LED, on/off |
| PAM-4 | 2 | 4 | 2 | A single-colour LED with PWM |
| RGB-8 | 3 | 8 | 3 | An RGB LED (e.g. WS2812) |
| *(reserved)* | 4 | 16 | 4 | RGB-16: 16 of the 27 colours with three levels per channel |
| *(reserved)* | 5 | 64 | 6 | RGB-64: four levels per channel |

Symbol appearance (the drive the device should use):

- **OOK:** 0 is off, 1 is fully on. On an RGB LED, "on" is any colour the device likes, white
  by default.
- **PAM-4:** linear drive (PWM duty out of 255) of 0, 31, 102, and 255. A camera's tone curve
  (about gamma 2.2) spaces those roughly evenly. The training sequence absorbs whatever it
  actually does. The PWM frequency should be at least 10 kHz, so no camera exposure sees it.
- **RGB-8:** symbol s has red = bit 2, green = bit 1, and blue = bit 0, each fully off or fully
  on. So 0 is black, 7 is white, 4 is red, and so on. With no intermediate levels, an LED's own
  slow PWM (a WS2812's is a few hundred Hz to a few kHz) never shows.

The decoder never relies on these values: it uses what the training sequence shows it. They're
here so that devices look alike and the symbols are well separated.

## 3. Frame

```
preamble   12 symbols   HI LO HI LO …                (binary)
sync        8 symbols   0xE4 as binary: HI HI HI LO LO HI LO LO
header      8 symbols   (version << 4) | mode, as binary
training    N symbols   0, 1, 2, … N−1
body        ⌈8·(len+3) / k⌉ symbols   whitened [length, payload, CRC], k bits per symbol
```

"Binary" means each bit is one symbol: 1 is HI and 0 is LO, whatever the mode. That way the
decoder can read everything before the training sequence with a simple bright/dark threshold.

### 3.1 Preamble

Twelve symbols alternating HI and LO, starting with HI. The decoder estimates the brightness
threshold, the symbol period, and the phase from its transitions.

### 3.2 Sync

The byte 0xE4 in binary marks the end of the preamble exactly. The decoder finds it by
correlation, which pins the phase to a whole symbol.

### 3.3 Header

One byte in binary. The high nibble is the protocol version (1). The low nibble is the mode
(§2). A decoder must ignore a frame whose version it doesn't know.

### 3.4 Training

Every symbol in the mode's alphabet once, in ascending order. The decoder records what each
symbol looks like (its mean colour) and decodes the body by nearest match.

### 3.5 Body

The bytes are:

| Field | Size | Contents |
|---|---|---|
| length | 1 | Payload length, 0–255 |
| payload | length | The message (§4 for a status report) |
| CRC | 2 | CRC-16/CCITT-FALSE, big-endian, over the header byte, length, and payload |

CRC-16/CCITT-FALSE has polynomial 0x1021, initial value 0xFFFF, no reflection, and no final
XOR. Its check value, over the ASCII bytes `123456789`, is 0x29B1.

### 3.6 Whitening

The body bytes are XORed with a PRBS9 sequence before they become symbols. That keeps
transitions frequent, so the decoder can track timing even through a run of zero bytes.

- The register is 9 bits, starting at 0x1FF.
- For each bit: the output is bit 8 of the register. The feedback is bit 8 XOR bit 4
  (x⁹ + x⁵ + 1). The register shifts left one place, takes the feedback into bit 0, and is
  masked to 9 bits.
- Output bits form bytes most significant bit first.
- The sequence starts afresh for every frame.

The first eight whitening bytes are `FF 83 DF 17 32 09 4E D1`.

### 3.7 Body symbols

The whitened bytes are a bit stream, taken k bits at a time, most significant first. Each
group is one symbol. The last group is padded with zero bits.

### 3.8 Between frames

A device may repeat a frame. Between repeats, and after the last frame, it shows LO for at
least 4 symbol periods. A decoder treats the gap as the end of the frame, so a truncated body
is caught by the length and the CRC.

## 4. Status report

The usual payload. Its first byte is the content type:

| Value | Content |
|---|---|
| 0x00 | Raw bytes: the reader shows them as hex |
| 0x01 | A status report: type-length-value fields follow |

Each field is one tag byte, one length byte (0–255), then the value:

| Tag | Field | Value |
|---|---|---|
| 0x01 | Device | UTF-8 |
| 0x02 | Firmware version | UTF-8 |
| 0x03 | Uptime | u32 LE, seconds |
| 0x04 | Battery | u16 LE, millivolts |
| 0x05 | State | UTF-8, a short message |
| 0x06 | Error code | u16 LE |
| 0x07 | ID / serial | bytes, shown as hex |
| 0x08 | Key–value | UTF-8 `key=value`; repeatable |
| 0x09 | Temperature | i16 LE, hundredths of a degree Celsius |
| 0x0A–0x7F | Reserved | Readers skip them |
| 0x80–0xFF | Device-specific | Readers show the tag number and the value as hex |

- A reader must skip a field whose tag it doesn't know, or whose length doesn't suit the type
  (for example, an uptime that isn't 4 bytes). It still shows the other fields.
- A field that runs past the end of the payload ends the report.

## 5. Timing

- The **symbol period** T is the device's choice. The decoder measures it, so it isn't sent.
- **Choose T to give the reader's camera at least 3 frames per symbol:**

  | Camera | T |
  |---|---|
  | Any (30 fps) | 100 ms |
  | 120 fps | 33 ms |
  | 240 fps | 16.7 ms |

  The LED Talks app films at the highest rate the phone offers, and 240 fps on recent
  iPhones. Devices should default to **33 ms** and let a long press or a setting choose
  100 ms.
- **The device's clock must be within ±2%** of its nominal period. That's easy for any crystal,
  or for a calibrated RC oscillator.
- **Jitter:** each symbol should start within T/10 of its nominal time. A timer interrupt, a
  hardware timer, or a high-priority task all meet it. A busy main loop may not.

## 6. Decoding (informative)

What the reference decoder in `LEDTalksKit` does. Others may differ, as long as they meet §7.

1. **Sampling.** For each frame, take the mean RGB of a small region of interest around the LED,
   with its timestamp. Lock exposure, ISO, and white balance first, so the training sequence
   stays valid for the whole message.
2. **Preamble.** Track brightness (luma). Find runs of alternating bright and dark, with the
   threshold at the midpoint of a running minimum and maximum. Fit the period and phase to the
   transition times by least squares.
3. **Sync and header.** Sample each symbol's middle 60%. Correlate the binary stream against
   the preamble tail plus the sync. Read the header, then check the version and the mode.
4. **Training.** Record the mean colour of each of the N training symbols.
5. **Body.** Classify each symbol to the nearest training colour. On a change of symbol, measure
   where the transition happened, and nudge the phase toward it (a simple first-order loop),
   so clock skew can't accumulate. De-whiten, read the length, read the payload, and check the
   CRC.
6. **Retry.** If the CRC fails, wait for the next preamble. Devices repeat their frames.

## 7. Test vectors

These come from `encoder/core` and are checked by both test suites. Symbols are written as
digits, with `|` between the frame's parts.

**CRC and whitening:**

- CRC over `123456789`: **0x29B1**.
- Whitening, first 8 bytes: `FF 83 DF 17 32 09 4E D1`.

**Payload `48 69` ("Hi"):**

| Mode | Header | CRC input | CRC | Symbols |
|---|---|---|---|---|
| OOK | 0x11 | `11 02 48 69` | 0xFE59 | 70 |
| PAM-4 | 0x12 | `12 02 48 69` | 0x6585 | 52 |
| RGB-8 | 0x13 | `13 02 48 69` | 0x1331 | 50 |

OOK. The whitened body is `FD CB B6 E9 6B`:

```
101010101010 | 11100100 | 00010001 | 01 | 1111110111001011101101101110100101101011
```

PAM-4. The whitened body is `FD CB B6 72 B7`:

```
303030303030 | 33300300 | 00030030 | 0123 | 33313023231213022313
```

RGB-8. The whitened body is `FD CB B6 04 03`:

```
707070707070 | 77700700 | 00070077 | 01234567 | 77345666010014
```

**Empty payload, OOK** (54 symbols):

```
101010101010 | 11100100 | 00010001 | 01 | 111111111010111010010010
```

**A status report** (device "fob", firmware "1.0.0", uptime 3600 s, battery 2950 mV), 23 bytes:

```
01 01 03 66 6F 62 02 05 31 2E 30 2E 30 03 04 10 0E 00 00 04 02 86 0B
```

The same report in RGB-8 (106 symbols):

```
707070707070 | 77700700 | 00070077 | 01234567 | 7210133605052146131517427712224172162707600500570604712141071327330124
```

## 8. To prove on a real phone

1. **Exposure lock.** Locked exposure and white balance hold steady for a whole message
   (several seconds) on an iPhone at 240 fps.
2. **Mains flicker.** Lighting at 100 Hz (50 Hz mains) doesn't upset a 33 ms period. The
   region of interest is mostly LED, so it shouldn't, but check it.
3. **PAM-4 separation.** The four PAM-4 levels stay separable at about 10–30 cm, with the LED
   neither saturating the sensor nor lost in noise.
4. **WS2812 primaries.** The eight RGB-8 colours stay separable through the camera's
   crosstalk.
5. **Throughput.** Measure it, and compare with the README's estimates.

If any of these fails, change the decoder or the recommended values, and give the change a
new protocol version only if the frame itself has to change.
