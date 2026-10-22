# Photo Cleaner — swipe cards

A native SwiftUI iPhone app with cards that slide left, right, up, and down. Includes directional badges, spring snap-back, velocity-aware flicks, a repeating card stack, accessible direction buttons, and Reduce Motion support. Cards use bundled SF Symbols and gradients; no network access or photo permissions are needed.

## Run

Requires macOS, Xcode 15 or later, and iOS 17 or later.

1. Open `PhotoCleaner.xcodeproj` in Xcode.
2. Select the PhotoCleaner target and an iPhone simulator.
3. Press Run (Command-R). For a physical iPhone, select your signing team in Signing & Capabilities first.

No third-party dependencies or installation step is required.

## Check the interaction

- Drag a card left, right, up, and down: its badge follows the dominant direction. Release past 90 points to advance to the next card.
- Try a short slow drag: the card springs back without advancing.
- Flick a card: the projected movement can advance it after at least 25 points of actual movement.
- Tap each arrow button: it performs the corresponding swipe. Inputs are locked during dismissal.
- Swipe through all four designs: the deck repeats.
- Enable Reduce Motion and VoiceOver: use the labeled arrow buttons to advance cards.

The cloud workspace runs Linux without Xcode or an iOS SDK. iOS compilation and these simulator/device checks must be performed on a Mac; they have not been run in the cloud.
