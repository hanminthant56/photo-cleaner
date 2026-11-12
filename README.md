# Photo Cleaner — swipe cards

A native SwiftUI iPhone app with cards that slide left, right, up, and down. Includes spring snap-back, velocity-aware flicks, a continuous card stack, VoiceOver swipe actions, and Reduce Motion support. A compact floating Swipe tab uses native Liquid Glass on iOS 26+ when built with Xcode 26+, with a material fallback for older systems. Cards use bundled SF Symbols and gradients; no network access or photo permissions are needed.

## Run

Requires macOS, Xcode 15 or later, and iOS 17 or later.

1. Open `PhotoCleaner.xcodeproj` in Xcode.
2. Select the PhotoCleaner target and an iPhone simulator.
3. Press Run (Command-R). For a physical iPhone, select your signing team in Signing & Capabilities first.

No third-party dependencies or installation step is required.

## Check the interaction

- Drag a card left, right, up, and down: the next card grows smoothly into place. Release past 90 points to advance to the next card.
- Try a short slow drag: the card springs back without advancing.
- Flick a card: the projected movement can advance it after at least 25 points of actual movement.
- Double-tap the card: a subtle outline briefly appears. The card stays in place and does not flip.
- Verify the floating Swipe tab remains clear of the home indicator; no status row, direction buttons, or footer should appear. Inputs are locked during dismissal.
- Swipe through all four designs: the deck repeats.
- Enable Reduce Motion and VoiceOver: use the card’s named swipe actions to advance cards.

The cloud workspace runs Linux without Xcode or an iOS SDK. iOS compilation and these simulator/device checks must be performed on a Mac; they have not been run in the cloud.
