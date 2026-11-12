# Photo Cleaner

Native SwiftUI photo and video sorting for iPhone. Requires iOS 17+ and Xcode 15+. Build with Xcode 26+ for native Liquid Glass on iOS 26+; older versions use a material fallback.

## Run on your Mac

Open `PhotoCleaner.xcodeproj`, select your signing team for a physical iPhone, select the device or simulator, and press Command-R. No third-party dependencies are needed. Add photos/videos to a simulator before testing (drag media onto the simulator).

## Workflow

- Tap Choose Photo Access. Choose full access for the whole library, or selected access for a subset. Denied/restricted access shows a Settings button; limited access is indicated in the app.
- The queue contains accessible, undecided photos and videos, newest first. Cards use an approximately 5:7 portrait frame, adapting to the screen. Media fits inside the frame without cropping.
- Swipe left to stage an item in **Recently Removed**. Swipe right to add it to **Kept**. Both remove the item from the queue. A red trash badge / green heart badge follows the drag, with a light haptic on commit.
- Short drags snap back. Up/down drags return to place without a decision. Double-taps toggle Favorites in Apple Photos without sorting the item. A spring heart/sparkle animation confirms adding a favorite, and a crossed-out heart confirms removal. A bottom-right heart badge marks existing favorites. The animation appears only after the Photos update succeeds.
- Tap the play button once to open and play a video, including iCloud media when available. Dismissing playback pauses it.
- The title's three-dot menu selects **All Photos** (the remaining queue), **Kept**, or **Recently Removed**. Collections use a grid; tap an item to inspect/play it or return it to the queue.
- Decisions are stored locally on this installation using Photos asset identifiers and survive relaunches. These collections are app-only, not albums created in Apple Photos. Swiping does not delete or modify originals. Double-tapping changes their Apple Photos favorite flag. Recently Removed offers explicit, confirmed deletion through Apple Photos. Uninstalling the app resets its decisions.
- Returning to the app refreshes library access and media. Unavailable iCloud items display an error rather than blocking the deck.

## Device validation checklist

1. Grant full access on a populated library and confirm photos and videos appear. Also test selected-only, denied, empty-library, and permission changes in Settings.
2. Swipe a photo left and another right. Check the direction badges, next-card handoff, collection contents, and that originals remain in Apple Photos.
3. Relaunch: decided items must remain out of the queue. Restore one through its collection and verify it returns.
4. Play a local video and an iCloud video; dismiss playback and verify audio stops.
5. Try short drags, vertical drags, rapid swipes, and VoiceOver's named Keep/Move to Recently Removed actions. Check Reduce Motion and large text on a smaller device.
6. Finish the queue, add a photo to Apple Photos, and return to the app; the new item should appear.

This Linux cloud workspace has no Xcode/iOS SDK. Source/configuration checks are performed here; iOS compilation, permissions, playback, and simulator/device behavior require validation on your Mac.

## Select and bulk actions

In Kept or Recently Removed, tap **Select**. Tap thumbnails or start a sideways drag across a row, then continue through the grid to select a range. Starting on a selected item deselects the range. Dragging back toward the starting item contracts the range. Ordinary vertical drags scroll between selection gestures. Select All, Deselect All, and Done are also available.

An action tray slides up for one or more selected items. **Return to Swipe Queue** restores all selected items in one operation. Recently Removed additionally offers **Delete**. With no selection, **Delete All** targets only the current Recently Removed collection, never the Kept collection or the remaining queue.

Deletion first shows an app confirmation with the item count, then uses the Photos system deletion request. If iOS denies the request or the user cancels it, decisions and collection records remain intact and an error is shown. Only a successful request clears the deleted IDs and refreshes the library. Apple Photos normally retains deleted items in its own Recently Deleted album for 30 days; this app does not bypass that recovery period. With limited access, bulk actions include only accessible items.

Test on a disposable set of media on a simulator/device:

- Select/deselect individual photos and videos, paint ranges in either direction, reverse a drag, scroll and continue selecting, and test Select All/Done.
- In Kept, select multiple items and return them to the queue; confirm they leave Kept and stay in Apple Photos.
- In Recently Removed, cancel Delete and Delete All at the app confirmation, and cancel/deny at the iOS prompt. All app records should remain.
- Confirm a selected deletion removes only the selected staged originals. Confirm Delete All with no selection removes only the staged collection. Verify Kept and undecided items remain in Apple Photos.
- Check deleted items in Apple Photos’ Recently Deleted album, relaunch the app, and verify no deleted items reappear in the queue.
- Test failed deletion (for example a system-restricted asset), empty collections, limited access, VoiceOver selection, large text, and Reduce Motion.

## Single-item deletion and Favorites validation

- Open an item in Recently Removed. Verify both Return to Swipe Queue and Delete appear. Cancel Delete and confirm the item remains. Confirm it and the iOS prompt; the detail view should close and the item should leave both the collection and the Apple Photos library. Kept item details must not offer Delete.
- Double-tap a non-favorite card. Verify the pink heart animation and favorite badge, then check the same item in Apple Photos Favorites. Double-tap again and confirm the crossed-out heart, removed badge, and removal from Apple Photos Favorites.
- Relaunch or change favorites in Apple Photos and return: badges should reflect the refreshed library. Favoriting must not add an item to Kept or remove it from the queue.
- Deny/cancel a favorite update if the system prompts: an error should appear without a success animation or a changed badge. Test repeated double-taps, swiping after a favorite update, Reduce Motion, and VoiceOver’s named favorite action.
