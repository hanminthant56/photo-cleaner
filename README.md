# Photo Cleaner

Native SwiftUI photo and video sorting for iPhone. Requires iOS 17+ and Xcode 15+. Build with Xcode 26+ for native Liquid Glass on iOS 26+; older versions use a material fallback.

## Run on your Mac

Open `PhotoCleaner.xcodeproj`, select your signing team for a physical iPhone, select the device or simulator, and press Command-R. No third-party dependencies are needed. Add photos/videos to a simulator before testing (drag media onto the simulator).

## Workflow

- Tap Choose Photo Access. Choose full access for the whole library, or selected access for a subset. Denied/restricted access shows a Settings button; limited access is indicated in the app.
- The queue contains accessible, undecided photos and videos, newest first. Cards use an approximately 5:7 portrait frame, adapting to the screen. Media fits inside the frame without cropping.
- Swipe left to stage an item in **Recently Removed**. Swipe right to add it to **Kept**. Both remove the item from the queue. A red trash badge / green heart badge follows the drag, with a light haptic on commit.
- Short drags snap back. Up/down drags return to place without a decision. Double-taps show a subtle outline without flipping or sorting.
- Tap the play button once to open and play a video, including iCloud media when available. Dismissing playback pauses it.
- The title's three-dot menu selects **All Photos** (the remaining queue), **Kept**, or **Recently Removed**. Collections use a grid; tap an item to inspect/play it or return it to the queue.
- Decisions are stored locally on this installation using Photos asset identifiers and survive relaunches. These collections are app-only, not albums created in Apple Photos. No originals are deleted or modified. Uninstalling the app resets its decisions.
- Returning to the app refreshes library access and media. Unavailable iCloud items display an error rather than blocking the deck.

## Device validation checklist

1. Grant full access on a populated library and confirm photos and videos appear. Also test selected-only, denied, empty-library, and permission changes in Settings.
2. Swipe a photo left and another right. Check the direction badges, next-card handoff, collection contents, and that originals remain in Apple Photos.
3. Relaunch: decided items must remain out of the queue. Restore one through its collection and verify it returns.
4. Play a local video and an iCloud video; dismiss playback and verify audio stops.
5. Try short drags, vertical drags, rapid swipes, and VoiceOver's named Keep/Move to Recently Removed actions. Check Reduce Motion and large text on a smaller device.
6. Finish the queue, add a photo to Apple Photos, and return to the app; the new item should appear.

This Linux cloud workspace has no Xcode/iOS SDK. Source/configuration checks are performed here; iOS compilation, permissions, playback, and simulator/device behavior require validation on your Mac.
