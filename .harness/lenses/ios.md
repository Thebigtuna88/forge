## Lens: ios

Use the simulator screenshots (in the evidence) and the code. Check:
- SwiftUI state handling: the right property wrappers, no state lost or duplicated on redraw.
- Dynamic Type: text scales at the largest sizes without clipping.
- VoiceOver: every control has a meaningful label; order makes sense.
- Contrast in light and dark mode.
- Memory and threading: retain cycles, work on the main thread that blocks it, UI updated off it.
- No secret in the app bundle, logs or user defaults.
