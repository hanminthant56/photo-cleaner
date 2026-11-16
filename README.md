# Photo Cleaner

Native SwiftUI photo and video sorting for iPhone. Requires iOS 17+ and Xcode 15+. Build with Xcode 26+ for native Liquid Glass on iOS 26+; older versions use a material fallback.

## Run on your Mac

Open `PhotoCleaner.xcodeproj`, select your signing team for a physical iPhone, select the device or simulator, and press Command-R. No third-party dependencies are needed. Add photos/videos to a simulator before testing (drag media onto the simulator).

## Workflow

- Tap Choose Photo Access. Choose full access for the whole library, or selected access for a subset. Denied/restricted access shows a Settings button; limited access is indicated in the app.
- The queue contains accessible, undecided photos and videos, newest first. Cards use an approximately 5:7 portrait frame, adapting to the screen. Media fits inside the frame without cropping.
- Swipe left to stage an item in **Recently Removed**. Swipe right to add it to **Kept**. Both remove the item from the queue. A red trash badge / green heart badge follows the drag, with a light haptic on commit.
- Short drags snap back. Downward swipes open Add to Album. Upward swipes reuse the last successfully used album, or open the picker if no writable previous album exists. Double-taps toggle Favorites in Apple Photos without sorting the item. A spring heart/sparkle animation confirms adding a favorite, and a mint outlined heart gently shrinks and fades to confirm removal. A bottom-right heart badge marks existing favorites. The animation appears only after the Photos update succeeds.
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

In Kept or Recently Removed, tap **Select**. Tap thumbnails or start a sideways drag across a row, then continue through the grid to select a range. Starting on a selected item deselects the range. Dragging back toward the starting item contracts the range. Ordinary vertical drags scroll between selection gestures. During an active range selection, hold near the top or bottom edge to scroll automatically; the speed increases toward the edge and selection continues through new rows. Select All, Deselect All, and Done are also available.

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
- Double-tap a non-favorite card. Verify the pink heart animation and favorite badge, then check the same item in Apple Photos Favorites. Double-tap again and confirm the mint outlined heart, removed badge, and removal from Apple Photos Favorites.
- Relaunch or change favorites in Apple Photos and return: badges should reflect the refreshed library. Favoriting must not add an item to Kept or remove it from the queue.
- Deny/cancel a favorite update if the system prompts: an error should appear without a success animation or a changed badge. Test repeated double-taps, swiping after a favorite update, Reduce Motion, and VoiceOver’s named favorite action.

## Favorite protection

Left-swiping a favorite returns the card to place and asks you to remove its favorite status first (double-tap the card). Single-item Delete, selected Delete, and Delete All also re-fetch the current Photos assets and reject the entire request if any target is a favorite. No non-favorite items in a mixed request are deleted. Remove the favorite heart in Apple Photos, or restore the item to the swipe queue and double-tap it, then retry.

Test a favorite left swipe, single-item deletion of an already-staged favorite, and a mixed favorite/non-favorite Delete All. Verify an error appears, no items move/delete, and selection remains. Remove the favorite flag and confirm the same operation succeeds.

## Paging and albums

Open a Kept or Recently Removed item and swipe horizontally to page through that collection. A position counter tracks the visible item; Return to Swipe Queue and Delete apply to the currently displayed item. Videos retain an explicit play button. Delete confirmation captures that item and favorites remain protected.

Swipe a queue card down to open a minimal Add to Album sheet, tap its bottom-left album button, or use its VoiceOver Add to album action. Tap an editable album to add the photo/video in Apple Photos. Smart/system/read-only albums are not listed as writable destinations. New Album asks for a nonempty name and creates the album and adds the item in one Photos transaction. A saved checkmark appears only on success. Cancel and errors leave the card in the queue; a successful album save moves the item to Kept and removes it from the queue.

Validate on your Mac/device:

- Open a middle item in each collection; swipe both ways and verify the counter, photos, video play buttons, and current-item restore/delete behavior. Check both ends of the collection.
- Swipe a photo and video down. Add each to an existing album and verify it in Apple Photos. Repeat adding to the same album; there should be no duplicated asset.
- Create an album, verify both its name and contents in Apple Photos, and confirm the item moves to Kept and disappears from the queue, including after relaunch.
- Test Cancel, an empty/whitespace name, limited photo access, no writable albums, system write denial, and VoiceOver Add to album.

After an existing-album or new-album save succeeds, the confirmation reads “Added to [album name] · Kept” and the next pending card becomes available. Kept is an app collection; no extra Apple Photos album named Kept is created. Test both album-save paths, cancel/error paths, and persistence after relaunch.

## Edge-selection and downward-swipe regression checks

With several screenfuls of Kept/Recently Removed media, enter Select, start a sideways range drag, and hold near the bottom edge without lifting. Confirm new rows scroll into view and become selected. Move toward the center to stop scrolling, then the top edge to reverse. Lift, cancel, leave the collection, or tap Done: scrolling must stop. Verify range deselection and reversing toward the anchor preserve pre-existing selections. Test both the first/last rows, large text, the action tray appearing, and Reduce Motion.

On the queue, test slow downward drags past 64 points and quick downward flicks, including slightly diagonal movements. The album picker should open. Short drags must snap back; left/right sorting and video play taps must still work. Verify the new album button opens the same picker and successful saves still move the item to Kept.

## Fixed gesture viewports

Main-card drags now measure translation in the fixed `swipeDeck` space, rather than the moving card. A downward drag shows a top-centered Album badge; horizontal drags show only Keep/Remove. Verify downward drags and flicks actually open the album picker, including drags starting over the image and its empty letterbox region.

The collection detail viewer uses a fixed-size, explicit three-item paging viewport instead of SwiftUI’s page-style TabView. Swipe left for the next item, right for the previous, or use the small chevron controls. At either end the image springs back. The counter and actions must track the visible item, including videos. Use Done to close; sheet swipe-to-dismiss is disabled to avoid competing gestures. Test repeated forward/backward swipes, short drags, boundary bounce, video playback, current-item restore/delete, and favorite protection.

## Swipe up: repeat last album

The app remembers the identifier of the last album successfully used, including newly created albums. Swipe up to add the current photo/video there and move it to Kept after Photos confirms success. A compact “Add to [name]” badge truncates long names in the middle; the success notice reads “Added to [name] · Kept.” Swipe down always opens the picker to choose a different album.

With no prior successful choice, or when that album is unavailable/read-only, swipe up opens the picker. Cancelled and failed saves never mark an item Kept or change the remembered album. Verify both existing/new-album paths, relaunch persistence, an album renamed/deleted in Photos, long names, limited access, failed writes, and rapid repeat swipes. Confirm original favorite and delete protection still apply.

## Kept collection actions

Kept now offers **Return All to Swipe Queue** when no items are selected, with a confirmation and item count. This resets only the app review decisions; existing Apple Photos albums and favorite flags remain unchanged.

Selected items in Kept offer both **Return to Swipe Queue** and **Delete**. Opening an individual Kept item also offers Delete. Both use the same Apple Photos confirmation, fresh favorite check, and success-only cleanup as Recently Removed. Delete All remains exclusive to Recently Removed. Favorite-containing deletion requests are blocked in full.

Verify Return All cancel/confirm, that only Kept decisions reset, persistence after relaunch, selected and single-item Kept deletion cancel/success, and favorite protection for both. On single-item deletion, verify the visible item is the one targeted after paging. iOS compilation and Photos behavior still require Xcode/device testing.

## Collection order

Kept and Recently Removed show the most recently reviewed items first, using locally persisted decision timestamps. This includes album saves that move items to Kept. Opening either collection starts with these newest items, and its detail viewer uses the same order. Restoring an item clears its review timestamp; sorting it again assigns a new timestamp. Existing decisions from older versions have no recorded review time, so they retain newest-photo-first ordering below newly reviewed items.

Check with an old photo: keep it and confirm it appears first even above newer photos. Do the same for Recently Removed. Relaunch and verify the order persists; restore and re-review an item, and verify it moves to the front again.

## Drag-selection performance

Collection items and their index lookup are cached until library/review data changes. Hit-testing examines laid-out cells, selection updates only when the endpoint changes, and only the changed range is applied. Entering Select reserves tray space to avoid moving the grid under the finger. Auto-scroll ramps speed using display-frame elapsed time and stops when the gesture ends.

On a physical phone with a large collection, test slow/fast range drags, reversing across the anchor, selecting/deselecting preselected items, and scrolling at both edges. Confirm the first selection does not shift the grid and lifting stops scrolling. Portable range-invariant checks run in the cloud; actual touch smoothness and iOS compilation require Mac/device validation.

## Faster photo viewing and swipe-down return

Grid, card, and viewer images share a bounded in-memory preview cache keyed by Photos identifier and modification time. The detail viewer can immediately display the loaded grid preview, accepts opportunistic low-resolution PhotoKit callbacks, and upgrades it while the larger image loads. Neighboring pages are loaded ahead, completed target-size requests are cached, and obsolete requests are cancelled with generation checks to prevent stale callbacks from changing reused views. iCloud-only images can still need a network download; immediate full-resolution display is not guaranteed.

In a Kept/Recently Removed item viewer, drag down past 72 points or flick down to close and return to that collection grid. Short drags spring back, horizontal drags still page, and closing does not restore or change the item’s review decision. Video playback remains a separate player sheet.

Test opening a visible thumbnail, paging forward/back, returning to a previously seen item, an edited photo, rapid open/close, iCloud-only media, and low-memory cache eviction. Verify downward close and horizontal navigation independently, plus short drags, Reduce Motion, and deletion confirmation/busy-state protection. Device timing still needs physical-phone validation.

## Pinch zoom and smooth viewer dismissal

Pinch queue cards and collection-viewer photos/posters to zoom from 1× to 5×. While zoomed, one-finger drags pan within bounds instead of sorting, album shortcuts, paging, or dismissal. Pinch back to 1× to resume those gestures; VoiceOver also offers Reset zoom. Double-tap still toggles Favorites on queue cards. Zoom resets on a new card/page, and viewer zoom does not alter the asset.

At 1× in the collection viewer, downward dragging follows your finger and scales the photo gently. A committed downward swipe continues out and fades the viewer before returning to the same grid; short drags spring back. Reduce Motion skips the movement. Deletion/confirmation and page-transition locks remain in effect.

Physical-device checks: pinch in/out repeatedly, pan to each edge at several zoom levels, zoom out while panned, verify no sort/album actions while pinching/panning, and verify Favorites double-tap remains. Swipe down slowly/quickly, cancel a short drag, page horizontally afterward, play a video, and test Reduce Motion. iOS compilation and gesture feel remain device validation steps.

## Temporary pinch zoom

Pinch-in/out changes magnification while touching the image. Releasing either card/viewer pinch returns scale and pan to the original 1× position with a gentle spring. Gesture-state cleanup also resets zoom when a pinch is interrupted. Reduce Motion restores without the spring. Zoom is no longer retained after release; double-tap Favorites and swipe actions remain unchanged.

On device, release at several magnifications and interrupt a pinch; check both surfaces settle smoothly, return to the original framing, and do not trigger sorting, paging, album actions, or dismissal during release.

## Pinch focal point and shrinking

Pinching now ranges from 0.5× to 5× while held. Both the main card and the collection viewer use the gesture’s initial pinch midpoint as their focal point, rather than always zooming into the center. Scaling uses fixed image viewports, with a compensating translation that keeps the touched image location stationary. Release still springs scale and position back to the original framing.

Test pinches at each corner, edges, and center; check both shrinking and enlarging, reversing within the same pinch, portrait/landscape photos, and rapid pinch release. Verify the chosen focal point stays under the fingers and release does not trigger a swipe action. Actual iOS gesture testing remains required.

## Moving while pinching

Cards and collection photos now use simultaneous native pinch and two-finger pan recognition. The image follows the moving finger midpoint while scale changes (including below 1×), instead of holding the initial midpoint in place. Lifting/cancelling ends the session and restores the original framing with the existing spring. The transparent gesture marker does not replace tap targets; native recognizers are removed when their view leaves the hierarchy.

Physical-device checks: keep two fingers touching and translate at constant spacing, translate while enlarging, translate while shrinking, change direction, and lift one/both fingers. Confirm no sudden jump, sorting, album action, or paging occurs during the two-finger interaction. Test several rapid sessions, video play taps afterward, double-tap Favorites, sheet opening/closing, and Reduce Motion. Cloud checks cover transform math and source wiring; native gesture behavior needs iPhone testing.

## Native viewer dismissal (replaces custom fade)

Collection viewers now use the native iOS sheet’s interactive downward dismissal. The custom photo drop, scale, fade-out, and unanimated second dismissal have been removed. Horizontal paging observes gestures simultaneously so it does not take priority over the sheet’s downward pan. Native dismissal is disabled during pinching, horizontal paging, and delete confirmation/requests. Done remains available.

On device, drag down slowly and reverse before release to verify the system cancels smoothly; complete a downward flick to return to the same collection without a fade. Also verify horizontal/diagonal paging, pinch release, video playback dismissal, and delete confirmation locks. This is native sheet behavior, not a custom reproduction of Apple Photos’ thumbnail-zoom transition.

## Return photos to their grid slots

The collection viewer is now an in-place overlay in the same SwiftUI hierarchy as the grid, replacing sheet-based viewing. Shared photo IDs and a matched-geometry namespace connect each grid thumbnail to its enlarged image. A downward drag reveals the grid behind the photo; commit returns the photo to its thumbnail slot with a spring. A short drag restores the viewer. Paging updates the source slot, and the underlying grid brings offscreen destinations into view without an extra scrolling animation. The photo itself has no fade transition.

Validate on iPhone: open a thumbnail and close by downward swipe/Done; cancel midway; navigate several items (including offscreen items) and close; verify the currently displayed photo lands in its own slot. Check cached previews, pinch-release, video presentation, selection mode, Reduce Motion, and single-item restore/delete. Matched-geometry behavior and device gesture feel remain unverified in this Linux workspace.

## Browsing/return transition separation

Normal left/right pages no longer use matched geometry. They keep a fixed viewport and full-size photo layout. While dragging down, the photo follows the finger and reveals the grid. On release, a separate cached return-image layer starts at the exact dragged frame and animates to the current asset’s measured thumbnail frame. The image never fades; only the backdrop clears. The viewer closes after the return animation completes. This replaces the previous matched-geometry implementation, which interfered with page sizing.

Device regression checks: page repeatedly in both directions and verify each photo stays full size. Drag down slowly, reverse/cancel, then complete; verify the photo starts its return from the release position and lands in the current item’s slot. Repeat after browsing to an offscreen item. Check video controls, pinch, source-thumbnail visibility after close, Reduce Motion, and single-item deletion/restore.

## Viewer controls and continuous browsing

The viewer title, Done button, position/navigation controls, and item actions hide as soon as a downward return drag begins. Their layout space is retained, keeping the image frame stable; controls return when a short drag springs back.

Horizontal paging now commits the next ID on release and uses an interruptible spring over stable page IDs. There is no completion callback or animation lock disabling the next gesture. Detail index lookup is cached and rebuilt only when library data changes. Test rapid consecutive swipes and reversals, boundary bounce, navigation buttons, downward return after rapid paging, and delete/restore targeting the visible item. Actual phone timing remains a device validation step.

## Return-slot clipping and timing

The collection records its actual scroll viewport below its toolbar. Return targets are brought fully into that viewport when needed, rather than treating any on-screen thumbnail as visible. The temporary returning image’s clip interpolates into the same scroll viewport, so the completed image cannot linger above the collection toolbar. Return now uses a fixed 0.22-second ease-out rather than waiting for a spring to settle. At logical completion, the cached grid thumbnail is restored and the temporary layer is removed in a transaction with animations disabled.

On phone, close items in the first/last visible row, after paging beyond the original screen, and near the toolbar boundary. Verify no overlap-then-underlap, no extra final resizing/fade, and that short cancelled drags, continuous horizontal paging, and pinches still behave correctly. Physical timing and rendering remain device validation steps.
