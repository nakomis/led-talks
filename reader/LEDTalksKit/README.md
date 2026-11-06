# LEDTalksKit

The Swift side of LED Talks (`docs/protocol.md`): a decoder, the status-report format, a Swift
twin of the encoder, and a synthetic camera for testing without hardware. Foundation only.

```swift
var decoder = Decoder()
// For each camera frame: the mean colour of a small region around the LED, and its time.
for event in decoder.add(Sample(time: t, colour: RGB(r, g, b))) {
    if case .decoded(let message) = event {
        for line in message.content.lines { print(line.label, line.value) }
    }
}
```

`SyntheticCamera` films any symbol sequence with a chosen frame rate, exposure, clock skew, tone
curve, white balance, colour crosstalk, ambient flicker, noise, jitter, and dropped frames.
The decoder tests use it end to end.

```sh
swift test                         # 22 tests
swift test --enable-code-coverage  # about 98% of lines
```
