# LED Talks app

The iPhone reader. Point the camera at a device's LED, tap the LED (or press **Find LED**), and
it shows what the LED says.

- It films at the fastest rate the phone offers, up to 240 fps, at the smallest resolution
  that rate allows (it only needs a few pixels).
- **Exposure** is fixed at half a frame, with a slider for the ISO (LEDs are bright, so low is
  usually right). White balance follows the scene for 1.5 s, then locks, so colours can't drift
  in the middle of a message.
- Every frame, the mean colour of a small square around the LED goes to `LEDTalksKit`'s decoder.
- **Find LED** watches for 1.5 s and picks the part of the picture whose brightness changed
  most: a talking LED, not a steady lamp.
- Repeats of the same message are counted, not listed again.

```sh
xcodegen generate
open LEDTalks.xcodeproj        # run on a phone: the simulator has no camera
```
