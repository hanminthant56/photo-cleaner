import SwiftUI
import Photos
import AVKit
import Combine

private enum LibrarySection: String, CaseIterable, Hashable {
    case all = "All Photos"
    case kept = "Kept"
    case removed = "Recently Removed"

    var symbol: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .kept: return "heart"
        case .removed: return "trash"
        }
    }
}

@MainActor
private final class PhotoLibrary: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published private(set) var reviewRevision = 0
    @Published var decisions: [String: String]
    @Published private(set) var decisionDates: [String: Double]
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var pending: [PHAsset] = []
    @Published private(set) var kept: [PHAsset] = []
    @Published private(set) var removed: [PHAsset] = []
    @Published private(set) var recentAlbum: PHAssetCollection?
    private enum LastAction {
        case review(id: String, decision: String?, date: Double?, addedAlbum: String?)
        case favorite(id: String, wasFavorite: Bool)
    }
    @Published private var lastAction: LastAction?
    private var addedAlbumForReview: [String: String] = [:]
    var canUndo: Bool { lastAction != nil }

    private let recentAlbumKey = "PhotoCleaner.recentAlbum.v1"
    private let storageKey = "PhotoCleaner.decisions.v1"
    private let datesKey = "PhotoCleaner.decisionDates.v1"

    init() {
        decisions = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        decisionDates = UserDefaults.standard.dictionary(forKey: datesKey) as? [String: Double] ?? [:]
        refreshRecentAlbum()
    }

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }

    func items(in section: LibrarySection) -> [PHAsset] {
        switch section {
        case .all: return pending
        case .kept: return kept
        case .removed: return removed
        }
    }

    private func orderedItems(in section: LibrarySection) -> [PHAsset] {
        return assets.filter { decisions[$0.localIdentifier] == section.rawValue }.sorted { lhs, rhs in
            let left = decisionDates[lhs.localIdentifier] ?? 0
            let right = decisionDates[rhs.localIdentifier] ?? 0
            if left != right { return left > right }
            // Older installations did not record review times. Keep their
            // existing newest-photo-first order, with a stable tie-breaker.
            let leftCreated = lhs.creationDate ?? .distantPast
            let rightCreated = rhs.creationDate ?? .distantPast
            if leftCreated != rightCreated { return leftCreated > rightCreated }
            return lhs.localIdentifier < rhs.localIdentifier
        }
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasAccess else { assets = []; pending = []; kept = []; removed = []; reviewRevision += 1; return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var loaded: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in loaded.append(asset) }
        assets = loaded
        reviewRevision += 1
        rebuildQueue()
        refreshRecentAlbum()
    }

    func decide(_ asset: PHAsset, section: LibrarySection) {
        let id = asset.localIdentifier
        lastAction = .review(id: id, decision: decisions[id], date: decisionDates[id],
                             addedAlbum: addedAlbumForReview.removeValue(forKey: id))
        decisions[asset.localIdentifier] = section.rawValue
        decisionDates[asset.localIdentifier] = Date().timeIntervalSince1970
        save()
    }

    func restore(_ asset: PHAsset) {
        lastAction = nil
        decisions.removeValue(forKey: asset.localIdentifier)
        decisionDates.removeValue(forKey: asset.localIdentifier)
        save()
    }

    func restore(_ items: [PHAsset]) {
        lastAction = nil
        for asset in items {
            decisions.removeValue(forKey: asset.localIdentifier)
            decisionDates.removeValue(forKey: asset.localIdentifier)
        }
        save()
    }

    func deleteReviewed(_ items: [PHAsset], from section: LibrarySection) async throws {
        // Deletion is limited to the explicitly opened review collection.
        guard section == .kept || section == .removed else {
            throw NSError(domain: "PhotoCleaner", code: 4, userInfo: [NSLocalizedDescriptionKey: "Choose items from Kept or Recently Removed before deleting."])
        }
        let staged = items.filter { decisions[$0.localIdentifier] == section.rawValue }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: staged.map(\.localIdentifier), options: nil)
        var candidates: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in candidates.append(asset) }
        guard !candidates.isEmpty else { return }
        guard !candidates.contains(where: { $0.isFavorite }) else {
            throw NSError(domain: "PhotoCleaner", code: 2, userInfo: [NSLocalizedDescriptionKey: "Favorites are protected. Remove the heart in Apple Photos before deleting these items. Nothing in this selection was deleted."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(candidates as NSArray)
        }
        lastAction = nil
        // Preserve decisions if iOS denies/cancels the request; update only on success.
        for asset in candidates {
            decisions.removeValue(forKey: asset.localIdentifier)
            decisionDates.removeValue(forKey: asset.localIdentifier)
        }
        save()
        refresh()
    }

    func toggleFavorite(_ asset: PHAsset) async throws -> Bool {
        let current = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject
        guard let current, current.canPerform(.properties) else {
            throw NSError(domain: "PhotoCleaner", code: 1, userInfo: [NSLocalizedDescriptionKey: "This item’s favorite status can’t be changed. Check Photos access in Settings."])
        }
        let wasFavorite = current.isFavorite
        let favorite = !wasFavorite
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: current).isFavorite = favorite
        }
        lastAction = .favorite(id: current.localIdentifier, wasFavorite: wasFavorite)
        refresh()
        return favorite
    }

    func editableAlbums() -> [PHAssetCollection] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let fetched = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        var albums: [PHAssetCollection] = []
        fetched.enumerateObjects { album, _, _ in
            if album.canPerform(.addContent) { albums.append(album) }
        }
        return albums
    }

    func add(_ asset: PHAsset, to album: PHAssetCollection) async throws {
        guard album.canPerform(.addContent) else {
            throw NSError(domain: "PhotoCleaner", code: 3, userInfo: [NSLocalizedDescriptionKey: "This album can’t be edited. Choose another album."])
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier == %@", asset.localIdentifier)
        let alreadyAdded = PHAsset.fetchAssets(in: album, options: options).count > 0
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
        }
        if !alreadyAdded { addedAlbumForReview[asset.localIdentifier] = album.localIdentifier }
        rememberAlbum(album.localIdentifier)
    }

    func createAlbum(named name: String, adding asset: PHAsset) async throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var createdID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            request.addAssets([asset] as NSArray)
            createdID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        if let createdID {
            addedAlbumForReview[asset.localIdentifier] = createdID
            rememberAlbum(createdID)
        }
    }

    func undoPreviousAction() async throws -> Bool {
        guard let action = lastAction else { return false }
        switch action {
        case let .review(id, decision, date, albumID):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                throw NSError(domain: "PhotoCleaner", code: 5, userInfo: [NSLocalizedDescriptionKey: "This item is no longer available in your photo library."])
            }
            if let albumID, let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
                guard album.canPerform(.removeContent) else {
                    throw NSError(domain: "PhotoCleaner", code: 6, userInfo: [NSLocalizedDescriptionKey: "This album can no longer be edited. The previous action was kept."])
                }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest(for: album)?.removeAssets([asset] as NSArray)
                }
            }
            decisions[id] = decision
            decisionDates[id] = date
            lastAction = nil
            save()
            refresh()
        case let .favorite(id, wasFavorite):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                throw NSError(domain: "PhotoCleaner", code: 5, userInfo: [NSLocalizedDescriptionKey: "This item is no longer available in your photo library."])
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).isFavorite = wasFavorite
            }
            lastAction = nil
            refresh()
        }
        return true
    }

    func refreshRecentAlbum() {
        guard hasAccess else { recentAlbum = nil; return }
        guard let id = UserDefaults.standard.string(forKey: recentAlbumKey) else { recentAlbum = nil; return }
        let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        recentAlbum = album?.canPerform(.addContent) == true ? album : nil
    }

    private func rememberAlbum(_ id: String) {
        UserDefaults.standard.set(id, forKey: recentAlbumKey)
        refreshRecentAlbum()
    }

    private func rebuildQueue() {
        pending = assets.filter { decisions[$0.localIdentifier] == nil }
        kept = orderedItems(in: .kept)
        removed = orderedItems(in: .removed)
        PhotoPreviewCache.shared.prewarm(Array(kept.prefix(8)) + Array(removed.prefix(8)))
    }

    private func save() {
        rebuildQueue()
        UserDefaults.standard.set(decisions, forKey: storageKey)
        UserDefaults.standard.set(decisionDates, forKey: datesKey)
        reviewRevision += 1
    }
}

struct ContentView: View {
    @StateObject private var library = PhotoLibrary()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: LibrarySection = .all
    @State private var offset: CGSize = .zero
    @State private var isDismissing = false
    @State private var playing: MediaSelection?
    @State private var inspected: MediaSelection?
    @State private var viewedID: String?
    @StateObject private var photoSlots = PhotoSlotFrames()
    @State private var albumTarget: MediaSelection?
    @State private var heartFeedback: HeartFeedback?
    @State private var isUpdatingFavorite = false
    @State private var isUndoing = false
    @State private var isSavingAlbum = false
    @State private var albumNotice: String?
    @State private var cardZoom = PhotoZoom()
    @State private var cardPinching = false
    @State private var cardPinchEnded = Date.distantPast
    @State private var photoActionError: String?

    private var progress: CGFloat { min(abs(offset.width) / 180, 1) }
    private var removing: Bool { offset.width < 0 }

    var body: some View {
        GeometryReader { window in
            mainContent
                .frame(width: window.size.width, height: window.size.height)
                .accessibilityHidden(inspected != nil)
                .overlay(alignment: .topLeading) {
                    if let selection = inspected {
                        CollectionDetail(library: library, section: section, initialID: selection.id,
                            slots: photoSlots, screenInsets: window.safeAreaInsets,
                            onPage: { viewedID = $0 }, onClose: {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    inspected = nil
                                    viewedID = nil
                                }
                            })
                            // The underlying content keeps its normal safe area and tab
                            // layout; only the viewer expands to all four window edges.
                            .frame(width: window.size.width + window.safeAreaInsets.leading + window.safeAreaInsets.trailing,
                                   height: window.size.height + window.safeAreaInsets.top + window.safeAreaInsets.bottom)
                            .offset(x: -window.safeAreaInsets.leading, y: -window.safeAreaInsets.top)
                            .transition(.identity)
                            .zIndex(10)
                    }
                }
        }
        .preferredColorScheme(.dark)
        .background(ShakeUndoReceiver(enabled: section == .all && inspected == nil && albumTarget == nil && playing == nil && !isDismissing && !isUpdatingFavorite && !isSavingAlbum && !isUndoing && scenePhase == .active) {
            undoPreviousAction()
        })
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            header
            if library.hasAccess {
                if library.authorization == .limited { limitedAccessNotice }
                if section == .all { swipeArea }
                else { collection(for: section) }
            } else {
                permissionView
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .background(Color(red: 0.035, green: 0.055, blue: 0.09).ignoresSafeArea())
        .foregroundStyle(.white)
        .safeAreaInset(edge: .bottom) { swipeTab.padding(.vertical, 8) }
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let albumNotice {
                Label(albumNotice, systemImage: "checkmark")
                    .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .padding(12).background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 32).padding(.top, 72)
                    .allowsHitTesting(false)
            }
        }
        .task(id: albumNotice) {
            guard albumNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            albumNotice = nil
        }
        .task { library.refresh() }
        .onChange(of: library.pending.first?.localIdentifier) { _, _ in cardZoom = PhotoZoom() }
        .onChange(of: cardPinching) { _, active in
            guard !active else { return }
            cardPinchEnded = Date()
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86)) {
                cardZoom = PhotoZoom()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !isDismissing { library.refresh() }
        }
        .alert("Couldn’t update photo", isPresented: Binding(
            get: { photoActionError != nil }, set: { if !$0 { photoActionError = nil } }
        )) {
            Button("OK", role: .cancel) { photoActionError = nil }
        } message: { Text(photoActionError ?? "Please try again.") }
        .sheet(item: $playing) { selection in VideoPlayback(asset: selection.asset) }
        .sheet(item: $albumTarget) { selection in
            AlbumPicker(library: library, asset: selection.asset)
        }
    }

    private var header: some View {
        HStack {
            TabPageTitle(title: "Swipe")
            Spacer()
            collectionMenu
        }
        .padding(.horizontal, 8)
    }

    private var collectionMenu: some View {
        Menu {
            ForEach(LibrarySection.allCases, id: \.self) { item in
                Button {
                    guard !isDismissing, !isUpdatingFavorite, !isSavingAlbum, !isUndoing else { return }
                    withAnimation { section = item }
                    offset = .zero
                } label: {
                    Label(item.rawValue, systemImage: section == item ? "checkmark" : item.symbol)
                }
            }
            Divider()
            Button("Undo Last Action", systemImage: "arrow.uturn.backward") { undoPreviousAction() }
                .disabled(!library.canUndo || isUndoing || isDismissing || isUpdatingFavorite || isSavingAlbum)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .disabled(isDismissing)
        .accessibilityLabel("Photo collections")
    }

    private var limitedAccessNotice: some View {
        HStack {
            Text("Showing selected photos and videos").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Manage") { openSettings() }.font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
    }

    private var permissionView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "photo.stack").font(.system(size: 54, weight: .light)).foregroundStyle(.mint)
            Text("A little space for your memories.").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text("Allow access to your photos and videos to start sorting. Choose All Photos for your whole library. Swiping never deletes an original from your iPhone.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if library.authorization == .notDetermined {
                Button("Choose Photo Access") { Task { await library.requestAccess() } }
                    .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
            } else {
                Button("Open Settings") { openSettings() }.buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(24)
    }

    private var swipeArea: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, 520)
            let height = min(width * 1.4, max(180, geometry.size.height - 72))
            VStack(spacing: 14) {
                Spacer(minLength: 8)
                if !library.pending.isEmpty {
                    deck(size: CGSize(width: width, height: height))
                    VStack(spacing: 5) {
                        Text("← remove · keep → · ↓ albums · ↑ repeat")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                Label("double-tap to favorite", systemImage: "heart")
                                Text("· shake to undo")
                            }
                            VStack(spacing: 4) {
                                Label("double-tap to favorite", systemImage: "heart")
                                Text("shake to undo")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                } else {
                    ContentUnavailableView(library.assets.isEmpty ? "No photos yet" : "All caught up", systemImage: "checkmark.circle", description: Text("Your kept and removed items are in the menu. New photos will appear here."))
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func deck(size: CGSize) -> some View {
        let visible = Array(library.pending.prefix(3))
        return ZStack {
            ForEach(Array(visible.reversed()), id: \.localIdentifier) { asset in
                let depth = visible.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) ?? 0
                mediaCard(asset: asset, depth: depth, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "swipeDeck")
        .accessibilityElement(children: .contain)
    }

    private func mediaCard(asset: PHAsset, depth: Int, size: CGSize) -> some View {
        let front = depth == 0
        let scale: CGFloat = front ? 1 : 1 - CGFloat(depth) * 0.035 + progress * 0.035
        let lift: CGFloat = front ? 0 : CGFloat(depth) * 10 - progress * 10
        return MediaCard(asset: asset, size: size, zoom: front ? cardZoom : PhotoZoom()) { playing = MediaSelection(asset: asset) }
            .overlay(alignment: removing ? .topTrailing : .topLeading) {
                if front && abs(offset.width) >= abs(offset.height) {
                    decisionBadge.opacity(Double(progress)).padding(20).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if front {
                    Button { openAlbums(for: asset) } label: {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain).padding(16)
                    .accessibilityLabel("Add to album")
                }
            }
            .overlay(alignment: .top) {
                if front && offset.height > abs(offset.width) {
                    Label("Album", systemImage: "rectangle.stack.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(12).background(.regularMaterial, in: Capsule())
                        .padding(.top, 20)
                        .opacity(Double(min(offset.height / 64, 1)))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if front && -offset.height > abs(offset.width) {
                    Label(library.recentAlbum.map { "Add to \($0.localizedTitle ?? "Album")" } ?? "Choose Album", systemImage: "rectangle.stack.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .padding(12).frame(maxWidth: min(size.width - 48, 280))
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 72)
                        .opacity(Double(min(-offset.height / 64, 1)))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if front && isSavingAlbum { ProgressView("Adding to album…").padding(18).background(.regularMaterial, in: Capsule()) }
            }
            .overlay {
                if front, let heartFeedback {
                    HeartCelebration(favorite: heartFeedback.favorite)
                        .id(heartFeedback.id)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(scale)
            .offset(y: lift)
            .offset(front ? offset : .zero)
            .rotationEffect(.degrees(front && !reduceMotion ? Double(offset.width / 45) : 0))
            .zIndex(Double(3 - depth))
            .allowsHitTesting(front && !isDismissing && !isSavingAlbum)
            .accessibilityHidden(!front)
            .contentShape(RoundedRectangle(cornerRadius: 28))
            .highPriorityGesture(swipeGesture(for: asset, size: size))
            .overlay {
                PinchMotionSurface(active: front && !isDismissing && !isSavingAlbum && !isUpdatingFavorite && albumTarget == nil && playing == nil) { motion in
                    if motion.ended { cardPinching = false }
                    else {
                        cardPinching = true
                        offset = .zero
                        cardZoom.magnify(motion.scale, anchor: motion.anchor, in: size, translation: motion.translation)
                    }
                }
            }
            .accessibilityAction(named: Text("Reset zoom")) { withAnimation { cardZoom = PhotoZoom() } }
            .simultaneousGesture(TapGesture(count: 2).onEnded { toggleFavorite(asset) })
            .accessibilityAction(named: Text(asset.isFavorite ? "Remove from Favorites" : "Add to Favorites")) { toggleFavorite(asset) }
            .accessibilityAction(named: Text("Add to album")) { openAlbums(for: asset) }
            .accessibilityAction(named: Text("Add to last album")) { reuseAlbum(for: asset, size: size) }
            .accessibilityAction(named: Text("Keep")) { decide(asset, keep: true, size: size) }
            .accessibilityAction(named: Text("Move to Recently Removed")) { decide(asset, keep: false, size: size) }
    }

    private var decisionBadge: some View {
        Label(removing ? "Remove" : "Keep", systemImage: removing ? "trash.fill" : "heart.fill")
            .font(.headline)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(removing ? Color.red : Color.green, in: Capsule())
            .foregroundStyle(.white)
            .scaleEffect(0.85 + progress * 0.15)
    }

    private func swipeGesture(for asset: PHAsset, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named("swipeDeck"))
            .onChanged { value in
                guard !isDismissing, !isUpdatingFavorite, !isSavingAlbum, !isUndoing else { return }
                guard !cardPinching, Date().timeIntervalSince(cardPinchEnded) > 0.12 else { return }
                if cardZoom.scale > 1.01 {
                    cardZoom.pan(value.translation, in: size)
                    return
                }
                offset = value.translation
            }
            .onEnded { value in
                guard !isDismissing, !isUpdatingFavorite, !isSavingAlbum, !isUndoing else { return }
                guard !cardPinching, Date().timeIntervalSince(cardPinchEnded) > 0.12 else { return }
                if cardZoom.scale > 1.01 { cardZoom.finishPan(); return }
                let actual = value.translation
                let projected = value.predictedEndTranslation
                let horizontal = abs(actual.width) > abs(actual.height)
                let crossed = abs(actual.width) > 90 || (abs(actual.width) > 25 && abs(projected.width) > 180)
                if actual.height > abs(actual.width) * 0.85 &&
                    (actual.height > 64 || (actual.height > 24 && projected.height > 140)) {
                    openAlbums(for: asset)
                } else if -actual.height > abs(actual.width) * 0.85 &&
                    (-actual.height > 64 || (-actual.height > 24 && projected.height < -140)) {
                    reuseAlbum(for: asset, size: size)
                } else if horizontal && crossed {
                    decide(asset, keep: actual.width > 0, size: size)
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)) { offset = .zero }
                }
            }
    }

    private func openAlbums(for asset: PHAsset) {
        guard !isDismissing, !isUpdatingFavorite, !isSavingAlbum, !isUndoing else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
            offset = .zero
        }
        albumTarget = MediaSelection(asset: asset)
    }

    private func reuseAlbum(for asset: PHAsset, size: CGSize) {
        guard !isDismissing, !isUpdatingFavorite, !isSavingAlbum, !isUndoing else { return }
        library.refreshRecentAlbum()
        guard let album = library.recentAlbum else {
            openAlbums(for: asset)
            return
        }
        isSavingAlbum = true
        Task { @MainActor in
            do {
                try await library.add(asset, to: album)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25), completionCriteria: .removed) {
                    offset = CGSize(width: 0, height: -size.height - 150)
                } completion: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        library.decide(asset, section: .kept)
                        offset = .zero
                        heartFeedback = nil
                        isSavingAlbum = false
                    }
                    albumNotice = "Added to \(album.localizedTitle ?? "Album") · Kept"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                isSavingAlbum = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { offset = .zero }
                photoActionError = error.localizedDescription
                library.refreshRecentAlbum()
            }
        }
    }

    private func decide(_ asset: PHAsset, keep: Bool, size: CGSize) {
        guard !isDismissing, !isUpdatingFavorite, !isSavingAlbum, !isUndoing else { return }
        if !keep {
            let current = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject
            if current?.isFavorite == true {
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)) { offset = .zero }
                photoActionError = "Favorites are protected. Double-tap the card to remove it from Favorites before swiping left."
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
        }
        isDismissing = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.95), completionCriteria: .removed) {
            offset = CGSize(width: (keep ? 1 : -1) * (size.width + 180), height: offset.height * 0.3)
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                library.decide(asset, section: keep ? .kept : .removed)
                offset = .zero
                isDismissing = false
                heartFeedback = nil
            }
        }
    }

    private func collection(for destination: LibrarySection) -> some View {
        CollectionBrowser(library: library, section: destination, slots: photoSlots, viewedID: viewedID) { asset in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewedID = asset.localIdentifier
                inspected = MediaSelection(asset: asset)
            }
        }
        .id(destination)
    }

    private var swipeTab: some View {
        Button { if !isDismissing { withAnimation { section = .all } } } label: {
            Label("Swipe", systemImage: "hand.draw.fill")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 22).frame(height: 48)
        }
        .buttonStyle(.plain).foregroundStyle(.mint)
        .modifier(FloatingTabGlass())
        .accessibilityAddTraits(.isSelected)
    }

    private func toggleFavorite(_ asset: PHAsset) {
        guard !isDismissing, !isUpdatingFavorite, !isSavingAlbum, !isUndoing, offset == .zero else { return }
        isUpdatingFavorite = true
        Task { @MainActor in
            do {
                let favorite = try await library.toggleFavorite(asset)
                heartFeedback = HeartFeedback(favorite: favorite)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                photoActionError = error.localizedDescription
            }
            isUpdatingFavorite = false
        }
    }

    private func undoPreviousAction() {
        guard library.canUndo, !isUndoing, !isDismissing, !isUpdatingFavorite, !isSavingAlbum else { return }
        isUndoing = true
        Task { @MainActor in
            do {
                if try await library.undoPreviousAction() {
                    offset = .zero
                    cardZoom = PhotoZoom()
                    heartFeedback = nil
                    albumNotice = "Previous action undone"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch { photoActionError = error.localizedDescription }
            isUndoing = false
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

private struct ShakeUndoReceiver: UIViewControllerRepresentable {
    let enabled: Bool
    let undo: () -> Void

    final class Controller: UIViewController {
        var enabled = false
        var undo: (() -> Void)?
        private var lastShake = Date.distantPast
        override var canBecomeFirstResponder: Bool { enabled }
        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if enabled { becomeFirstResponder() }
        }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard enabled, motion == .motionShake, Date().timeIntervalSince(lastShake) > 1 else { return }
            lastShake = Date()
            undo?()
        }
    }

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.undo = undo
        let changed = controller.enabled != enabled
        controller.enabled = enabled
        if changed {
            DispatchQueue.main.async { [weak controller] in
                guard let controller else { return }
                if controller.enabled { controller.becomeFirstResponder() }
                else { controller.resignFirstResponder() }
            }
        }
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.enabled = false
        controller.undo = nil
        controller.resignFirstResponder()
    }
}

private struct CollectionFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct DeletionRequest: Identifiable {
    let id = UUID()
    let assets: [PHAsset]
}

private struct CollectionBrowser: View {
    @ObservedObject var library: PhotoLibrary
    let section: LibrarySection
    let slots: PhotoSlotFrames
    let viewedID: String?
    let inspect: (PHAsset) -> Void
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSelecting = false
    @State private var selected: Set<String> = []
    @State private var frames: [String: CGRect] = [:]
    @State private var anchor: Int?
    @State private var lastEndpoint: Int?
    @State private var items: [PHAsset] = []
    @State private var indicesByID: [String: Int] = [:]
    @State private var dragBase: Set<String> = []
    @State private var dragAdds = true
    @State private var dragLocation: CGPoint?
    @GestureState private var selectionTouchActive = false
    @State private var deletion: DeletionRequest?
    @State private var returnAll: [PHAsset]?
    @State private var isDeleting = false
    @State private var errorMessage: String?

    init(library: PhotoLibrary, section: LibrarySection, slots: PhotoSlotFrames,
         viewedID: String?, inspect: @escaping (PHAsset) -> Void) {
        _library = ObservedObject(wrappedValue: library)
        self.section = section
        self.slots = slots
        self.viewedID = viewedID
        self.inspect = inspect
        let initialItems = library.items(in: section)
        _items = State(initialValue: initialItems)
        _indicesByID = State(initialValue: Dictionary(uniqueKeysWithValues: initialItems.enumerated().map { ($0.element.localIdentifier, $0.offset) }))
    }

    private var chosen: [PHAsset] { items.filter { selected.contains($0.localIdentifier) } }

    var body: some View {
        VStack(spacing: 12) {
            collectionToolbar
            ScrollViewReader { scrollProxy in
            ScrollView {
                if items.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: section.symbol)
                        .padding(.top, 48)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(items, id: \.localIdentifier) { asset in
                            collectionCell(asset).id(asset.localIdentifier)
                        }
                    }
                    .padding(.vertical, 8)
                    .background(SelectionAutoScroller(location: dragLocation, active: anchor != nil && selectionTouchActive))
                }
            }
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { slots.viewport = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in slots.viewport = frame }
            })
            .onPreferenceChange(CollectionFrames.self) { updated in
                frames = updated
                slots.frames = updated
                if let location = dragLocation { updateSelection(at: location) }
            }
            .onChange(of: selectionTouchActive) { _, active in
                if !active { endSelectionDrag() }
            }
            .scrollDisabled(anchor != nil)
            .simultaneousGesture(selectionDrag)
            .onChange(of: viewedID) { _, id in
                guard let id else { return }
                // Keep the current photo's real slot laid out beneath the viewer.
                if frames[id].map({ slots.viewport.contains($0.insetBy(dx: 1, dy: 1)) }) != true {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrollProxy.scrollTo(id, anchor: .center) }
                }
            }
            }
        }
        .disabled(isDeleting)
        // Reserve the action area before dragging starts so the grid does not jump
        // when the first item is selected or the last item is deselected.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting { Color.clear.frame(height: 184) }
        }
        .overlay(alignment: .bottom) {
            Group {
                if !selected.isEmpty {
                    selectionTray
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selected.isEmpty)
        }
        .onDisappear { endSelectionDrag() }
        .onChange(of: library.reviewRevision) { _, _ in reloadItems() }
        .confirmationDialog("Return all kept items?", isPresented: Binding(
            get: { returnAll != nil }, set: { if !$0 { returnAll = nil } }
        ), titleVisibility: .visible, presenting: returnAll) { assets in
            Button("Return All to Swipe Queue") {
                library.restore(assets)
                selected.removeAll()
                endSelectionDrag()
                returnAll = nil
            }
            Button("Cancel", role: .cancel) { returnAll = nil }
        } message: { assets in
            Text("All \(assets.count) kept items will return to the swipe queue. Your Apple Photos albums and favorites stay unchanged.")
        }
        .confirmationDialog("Delete from Apple Photos?", isPresented: Binding(
            get: { deletion != nil },
            set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible, presenting: deletion) { request in
            Button("Delete \(request.assets.count) item(s)", role: .destructive) {
                delete(request.assets)
            }
            Button("Cancel", role: .cancel) { deletion = nil }
        } message: { request in
            Text("These \(request.assets.count) items will be deleted from your iPhone photo library and synced devices. Apple Photos normally keeps them in its Recently Deleted album for 30 days.")
        }
        .alert("Couldn’t delete items", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
        .overlay { if isDeleting { ProgressView("Deleting…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
    }

    private var collectionToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(section.rawValue).font(.title2.weight(.semibold))
                Spacer()
                if !items.isEmpty {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { selected.removeAll(); endSelectionDrag() }
                    }
                    .font(.subheadline.weight(.semibold)).tint(.mint)
                }
            }
            if section == .removed {
                Text("Staged here until you confirm deletion from Apple Photos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if isSelecting {
                    Button(selected.count == items.count ? "Deselect All" : "Select All") {
                        selected = selected.count == items.count ? [] : Set(items.map(\.localIdentifier))
                    }
                    .font(.caption.weight(.semibold)).disabled(items.isEmpty)
                }
                Spacer()
                if section == .kept && selected.isEmpty && !items.isEmpty {
                    Button { returnAll = items } label: {
                        Label("Return All to Swipe Queue", systemImage: "arrow.uturn.backward")
                    }
                    .font(.subheadline.weight(.semibold)).tint(.mint)
                }
                if section == .removed && selected.isEmpty && !items.isEmpty {
                    Button("Delete All", role: .destructive) { deletion = DeletionRequest(assets: items) }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(minHeight: 28)
            if isSelecting {
                Text("Drag across items to select. Hold near the top or bottom to keep scrolling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
    }

    private func collectionCell(_ asset: PHAsset) -> some View {
        let checked = selected.contains(asset.localIdentifier)
        return Button {
            if isSelecting {
                if checked { selected.remove(asset.localIdentifier) }
                else { selected.insert(asset.localIdentifier) }
            } else { inspect(asset) }
        } label: {
            GeometryReader { geometry in
                AssetThumbnail(asset: asset, target: CGSize(width: ceil(geometry.size.width * displayScale), height: ceil(210 * displayScale)))
                    .frame(width: geometry.size.width, height: 210)
            }
                .frame(height: 210).frame(maxWidth: .infinity)
                .background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .opacity(viewedID == asset.localIdentifier ? 0 : 1)
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(checked ? Color.mint : .clear, lineWidth: 3) }
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting {
                        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundStyle(checked ? Color.mint : .white)
                            .background(.black.opacity(0.45), in: Circle()).padding(10)
                    } else if asset.mediaType == .video {
                        Image(systemName: "play.circle.fill").font(.title).padding(10)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.mediaType == .video ? "Video" : "Photo")
        .accessibilityValue(checked ? "Selected" : "Not selected")
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CollectionFrames.self, value: [asset.localIdentifier: proxy.frame(in: .global)])
        })
    }

    private var selectionDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($selectionTouchActive) { _, active, _ in active = true }
            .onChanged { value in
                guard isSelecting, !isDeleting else { return }
                if anchor == nil {
                    // Let ordinary vertical drags scroll. A sideways start paints a range.
                    guard abs(value.translation.width) > abs(value.translation.height),
                          let start = index(at: value.startLocation) else { return }
                    anchor = start
                    dragBase = selected
                    dragAdds = !selected.contains(items[start].localIdentifier)
                }
                dragLocation = value.location
                updateSelection(at: value.location)
            }
            .onEnded { _ in endSelectionDrag() }
    }

    private func updateSelection(at point: CGPoint) {
        guard let start = anchor, items.indices.contains(start) else { return }
        // Hit-test only laid-out cells, rather than scanning the entire library.
        let id = frames.first(where: { $0.value.contains(point) })?.key
            ?? frames.min(by: { distance(to: $0.value, from: point) < distance(to: $1.value, from: point) })?.key
        guard let id, let end = indicesByID[id], end != lastEndpoint else { return }
        let nextRange = min(start, end)...max(start, end)
        let previousRange = lastEndpoint.map { min(start, $0)...max(start, $0) }
        let lower = min(lastEndpoint ?? start, end)
        let upper = max(lastEndpoint ?? start, end)
        var updated = selected
        // Only touch cells entering/leaving the range. Preserve the pre-drag state
        // when the finger reverses, including range deselection.
        for index in lower...upper {
            let wasInRange = previousRange?.contains(index) ?? false
            let isInRange = nextRange.contains(index)
            guard wasInRange != isInRange else { continue }
            let identifier = items[index].localIdentifier
            let shouldSelect = isInRange ? dragAdds : dragBase.contains(identifier)
            if shouldSelect { updated.insert(identifier) }
            else { updated.remove(identifier) }
        }
        lastEndpoint = end
        if updated != selected { selected = updated }
    }

    private func distance(to rect: CGRect, from point: CGPoint) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private func endSelectionDrag() {
        anchor = nil
        lastEndpoint = nil
        dragLocation = nil
        dragBase.removeAll()
    }

    private func index(at point: CGPoint) -> Int? {
        guard let id = frames.first(where: { $0.value.contains(point) })?.key else { return nil }
        return indicesByID[id]
    }

    private var selectionTray: some View {
        VStack(spacing: 12) {
            Text("\(selected.count) selected").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Button {
                library.restore(chosen)
                selected.removeAll()
            } label: {
                Label("Return to Swipe Queue", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.bordered).tint(.mint)
            if section == .kept || section == .removed {
                Button(role: .destructive) { deletion = DeletionRequest(assets: chosen) } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.bordered).tint(.red)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.vertical, 8)
    }

    private func reloadItems() {
        endSelectionDrag()
        items = library.items(in: section)
        indicesByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.localIdentifier, $0.offset) })
        selected.formIntersection(Set(indicesByID.keys))
    }

    private func delete(_ assets: [PHAsset]) {
        guard !isDeleting, !assets.isEmpty else { return }
        isDeleting = true
        deletion = nil
        Task { @MainActor in
            do {
                try await library.deleteReviewed(assets, from: section)
                selected.subtract(assets.map(\.localIdentifier))
            } catch {
                errorMessage = "Nothing was removed by the app. \(error.localizedDescription)"
            }
            isDeleting = false
        }
    }
}

/// Adjusts the enclosing SwiftUI scroll view every display frame while a selection
/// finger rests near its edges. Programmatic scrolling works with scrolling disabled.
private struct SelectionAutoScroller: UIViewRepresentable {
    let location: CGPoint?
    let active: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.marker = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.location = location
        context.coordinator.setActive(active)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    final class Coordinator: NSObject {
        weak var marker: UIView?
        var location: CGPoint?
        private var link: CADisplayLink?
        private var velocity: CGFloat = 0
        private var lastTimestamp: CFTimeInterval?

        func setActive(_ active: Bool) {
            if active && link == nil {
                let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
                displayLink.add(to: .main, forMode: .common)
                link = displayLink
            } else if !active {
                link?.invalidate()
                link = nil
                velocity = 0
                lastTimestamp = nil
            }
        }

        @objc private func tick(_ displayLink: CADisplayLink) {
            guard let location, let marker, marker.window != nil else { return }
            var ancestor = marker.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else { return }
            let point = scroll.convert(location, from: nil)
            let y = point.y - scroll.bounds.minY
            let top = scroll.adjustedContentInset.top
            let bottom = scroll.bounds.height - scroll.adjustedContentInset.bottom
            let zone = min(CGFloat(80), (bottom - top) / 3)
            guard zone > 0 else { return }
            let speed: CGFloat
            if y < top + zone { speed = -min(1, max(0, (top + zone - y) / zone)) * 480 }
            else if y > bottom - zone { speed = min(1, max(0, (y - bottom + zone) / zone)) * 480 }
            else { velocity = 0; lastTimestamp = displayLink.timestamp; return }
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let dt = min(max(displayLink.timestamp - (lastTimestamp ?? displayLink.timestamp - displayLink.duration), 0), 1.0 / 30.0)
            lastTimestamp = displayLink.timestamp
            velocity += (speed - velocity) * min(1, CGFloat(dt) * 12)
            let next = min(maximum, max(minimum, scroll.contentOffset.y + velocity * CGFloat(dt)))
            if abs(next - scroll.contentOffset.y) > 0.01 {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
            }
        }
    }
}

private struct MediaSelection: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

/// Native two-finger recognizers track scale AND the moving finger midpoint.
/// The marker does not intercept taps, play buttons, or single-finger swipes.
private struct PinchMotionSurface: UIViewRepresentable {
    struct Motion {
        let scale: CGFloat
        let anchor: UnitPoint
        let translation: CGSize
        var ended = false
    }

    let active: Bool
    let onMotion: (Motion) -> Void

    final class Marker: UIView {
        var hierarchyChanged: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); hierarchyChanged?() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); hierarchyChanged?() }
    }

    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.isUserInteractionEnabled = false
        marker.hierarchyChanged = { [weak coordinator = context.coordinator, weak marker] in
            if let marker { coordinator?.attach(marker) }
        }
        return marker
    }

    func updateUIView(_ marker: Marker, context: Context) {
        let coordinator = context.coordinator
        coordinator.callback = onMotion
        coordinator.active = active
        coordinator.attach(marker)
        if !active { coordinator.finish() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ marker: Marker, coordinator: Coordinator) {
        coordinator.detach()
        marker.hierarchyChanged = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var marker: Marker?
        weak var host: UIView?
        var callback: ((Motion) -> Void)?
        var active = false
        private var start: CGPoint?
        private var scale: CGFloat = 1
        private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(changed(_:)))
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(changed(_:)))

        func attach(_ marker: Marker) {
            self.marker = marker
            guard marker.window != nil, var candidate = marker.superview else { return }
            // Observe touches on the hosting view while keeping the marker transparent.
            while !(candidate.next is UIViewController), let parent = candidate.superview, !(parent is UIWindow) {
                candidate = parent
            }
            guard host !== candidate else { return }
            detach()
            self.marker = marker
            host = candidate
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            for gesture in [pinch as UIGestureRecognizer, pan] {
                gesture.delegate = self
                gesture.cancelsTouchesInView = false
                candidate.addGestureRecognizer(gesture)
            }
        }

        func detach() {
            finish()
            host?.removeGestureRecognizer(pinch)
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard active, let marker, marker.window != nil else { return false }
            return marker.bounds.contains(touch.location(in: marker))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func changed(_ gesture: UIGestureRecognizer) {
            guard active, let marker else { finish(); return }
            switch gesture.state {
            case .began, .changed:
                guard gesture.numberOfTouches >= 2 else { return }
                let point = gesture.location(in: marker)
                if start == nil { start = point; scale = 1 }
                if gesture === pinch { scale = pinch.scale }
                guard let start else { return }
                callback?(Motion(scale: scale,
                    anchor: UnitPoint(x: start.x / max(marker.bounds.width, 1), y: start.y / max(marker.bounds.height, 1)),
                    translation: CGSize(width: point.x - start.x, height: point.y - start.y)))
            case .ended, .cancelled:
                finish()
            // One recognizer can fail while the other is actively tracking;
            // that must not reset a valid two-finger session.
            default: break
            }
        }

        func finish() {
            guard start != nil else { return }
            start = nil
            scale = 1
            callback?(Motion(scale: 1, anchor: .center, translation: .zero, ended: true))
        }
    }
}

/// Shared zoom math for queue cards and the collection viewer.
private struct PhotoZoom {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    private var baseOffset: CGSize = .zero

    mutating func magnify(_ magnification: CGFloat, anchor: UnitPoint, in size: CGSize, translation: CGSize = .zero) {
        scale = min(5, max(0.5, magnification))
        // Scaling about the center plus this translation keeps the point under
        // the initial pinch midpoint fixed, for both enlarging and shrinking.
        offset = CGSize(width: (0.5 - anchor.x) * size.width * (scale - 1) + translation.width,
                        height: (0.5 - anchor.y) * size.height * (scale - 1) + translation.height)
        baseOffset = offset
    }

    mutating func pan(_ translation: CGSize, in size: CGSize) {
        let xLimit = max(0, size.width * (scale - 1) / 2)
        let yLimit = max(0, size.height * (scale - 1) / 2)
        offset = CGSize(width: min(xLimit, max(-xLimit, baseOffset.width + translation.width)),
                        height: min(yLimit, max(-yLimit, baseOffset.height + translation.height)))
    }

    mutating func finishPan() { baseOffset = offset }
}

private struct MediaCard: View {
    let asset: PHAsset
    let size: CGSize
    var zoom = PhotoZoom()
    let play: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.10, blue: 0.14)
            AssetThumbnail(asset: asset, target: CGSize(width: size.width * 2, height: size.height * 2))
                .frame(width: size.width, height: size.height)
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
            if asset.mediaType == .video {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 68, height: 68)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Play video")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.12)))
        .overlay(alignment: .bottomTrailing) {
            if asset.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.pink)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(16)
                    .accessibilityLabel("Favorite in Apple Photos")
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .accessibilityLabel(asset.mediaType == .video ? "Video" : "Photo")
    }
}

/// Shared previews let grid thumbnails paint the detail view before Photos finishes
/// a larger request. Keys include modification time so edited images are refreshed.
private final class PhotoPreviewCache {
    static let shared = PhotoPreviewCache()
    let manager = PHCachingImageManager()
    private final class Preview {
        let image: UIImage
        let complete: Bool
        init(image: UIImage, complete: Bool) { self.image = image; self.complete = complete }
    }
    private let previews = NSCache<NSString, Preview>()
    private let images = NSCache<NSString, UIImage>()
    private var warmRequests: [String: PHImageRequestID] = [:]
    private var warmKeys: Set<String> = []

    private init() {
        images.totalCostLimit = 48 * 1024 * 1024
        images.countLimit = 80
        previews.totalCostLimit = 48 * 1024 * 1024
        previews.countLimit = 80
    }

    func key(_ asset: PHAsset) -> String {
        "\(asset.localIdentifier)/\(asset.modificationDate?.timeIntervalSince1970 ?? 0)"
    }

    func preview(_ asset: PHAsset) -> UIImage? {
        previews.object(forKey: key(asset) as NSString)?.image
    }

    func rendered(_ asset: PHAsset, target: CGSize) -> UIImage? {
        images.object(forKey: renderKey(asset, target: target) as NSString)
    }

    func store(_ image: UIImage, asset: PHAsset, target: CGSize, final: Bool) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        let old = previews.object(forKey: key(asset) as NSString)
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        let oldPixels = old.map { $0.image.size.width * $0.image.size.height * $0.image.scale * $0.image.scale } ?? 0
        // Quality outranks size: a large fast preview must not block a sharp result.
        if old == nil || (final && old?.complete == false) || (final == old?.complete && pixels >= oldPixels) {
            previews.setObject(Preview(image: image, complete: final), forKey: key(asset) as NSString, cost: cost)
        }
        if final { images.setObject(image, forKey: renderKey(asset, target: target) as NSString, cost: cost) }
    }

    /// Prepare just the first visible rows, without starting iCloud downloads.
    func prewarm(_ assets: [PHAsset]) {
        warmKeys = Set(assets.map { key($0) })
        let obsolete = warmRequests.keys.filter { !warmKeys.contains($0) }
        for id in obsolete {
            if let request = warmRequests.removeValue(forKey: id) { manager.cancelImageRequest(request) }
        }
        let target = CGSize(width: 400, height: 480)
        for asset in assets {
            let id = key(asset)
            guard preview(asset) == nil, warmRequests[id] == nil else { continue }
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            warmRequests[id] = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { [weak self] image, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.warmKeys.contains(id) else { return }
                    // fastFormat is only a placeholder, even when PhotoKit does
                    // not label its result degraded. Never fill the final cache.
                    if let image { self.store(image, asset: asset, target: target, final: false) }
                    self.warmRequests.removeValue(forKey: id)
                }
            }
        }
    }

    private func renderKey(_ asset: PHAsset, target: CGSize) -> String {
        "render/\(key(asset))/\(Int(target.width))x\(Int(target.height))"
    }
}

private final class ThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false
    private var request: PHImageRequestID?
    private var generation = UUID()

    init(asset: PHAsset) { image = PhotoPreviewCache.shared.preview(asset) }

    func load(asset: PHAsset, target: CGSize) {
        cancel()
        guard target.width > 0, target.height > 0 else { return }
        let cache = PhotoPreviewCache.shared
        if let rendered = cache.rendered(asset, target: target) {
            image = rendered
            failed = false
            return
        }
        image = cache.preview(asset)
        failed = false
        let token = generation
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        request = cache.manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !cancelled else { return }
                if let image {
                    cache.store(image, asset: asset, target: target, final: !degraded)
                    // Do not replace the cached preview with a smaller interim image.
                    self.image = degraded ? (cache.preview(asset) ?? image) : image
                    self.failed = false
                } else if !degraded { self.failed = self.image == nil }
                if !degraded { self.request = nil }
            }
        }
    }

    func cancel() {
        generation = UUID()
        if let request { PhotoPreviewCache.shared.manager.cancelImageRequest(request) }
        request = nil
    }
}

private struct AssetThumbnail: View {
    let asset: PHAsset
    let target: CGSize
    @StateObject private var loader: ThumbnailLoader

    init(asset: PHAsset, target: CGSize) {
        self.asset = asset
        self.target = target
        _loader = StateObject(wrappedValue: ThumbnailLoader(asset: asset))
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if loader.failed {
                Label("Unable to load from iCloud", systemImage: "icloud.slash")
                    .font(.caption).foregroundStyle(.secondary).padding()
            } else { ProgressView().tint(.white) }
        }
        .onAppear { loader.load(asset: asset, target: target) }
        .onChange(of: PhotoPreviewCache.shared.key(asset)) { _, _ in loader.load(asset: asset, target: target) }
        .onChange(of: target) { _, size in loader.load(asset: asset, target: size) }
        .onDisappear { loader.cancel() }
    }
}

private struct VideoPlayback: View {
    let asset: PHAsset
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player { VideoPlayer(player: player) }
            else if failed { Text("This video could not be loaded. Check your iCloud connection.").padding() }
            else { ProgressView("Loading video…") }
        }
        .preferredColorScheme(.dark)
        .task {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            let item: AVPlayerItem? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                    continuation.resume(returning: item)
                }
            }
            guard !Task.isCancelled else { return }
            if let item {
                let loaded = AVPlayer(playerItem: item)
                player = loaded
                loaded.play()
            } else { failed = true }
        }
        .onDisappear { player?.pause(); player = nil }
    }
}

private final class PhotoSlotFrames: ObservableObject {
    // Geometry is sampled by the grid and read only when closing a photo.
    // It deliberately does not publish scrolling updates through the whole app.
    var frames: [String: CGRect] = [:]
    var viewport: CGRect = .zero
}

/// Neighbor pages stay inside the photo viewport. Only a downward return drag
/// expands its lower edge, while the action controls are hidden.
private struct PhotoPagerVisibleArea: Shape {
    var downwardExtension: CGFloat
    var animatableData: CGFloat {
        get { downwardExtension }
        set { downwardExtension = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                    height: rect.height + max(0, downwardExtension)))
    }
}

private struct CollectionDetail: View {
    @ObservedObject var library: PhotoLibrary
    let section: LibrarySection
    let slots: PhotoSlotFrames
    let screenInsets: EdgeInsets
    let onPage: (String) -> Void
    let onClose: () -> Void
    @State private var currentID: String
    @State private var playing: MediaSelection?
    @State private var confirmation: MediaSelection?
    @State private var isDeleting = false
    @State private var deletionError: String?
    @State private var pageDrag: CGFloat = 0
    @State private var returnDrag: CGSize = .zero
    @State private var viewportFrame: CGRect = .zero
    @State private var returningAsset: PHAsset?
    @State private var returnFrame: CGRect = .zero
    @State private var returnClipFrame: CGRect = .zero
    @State private var returnBackdrop: Double = 0
    @State private var opening = false
    @State private var openingStarted = false
    @State private var zoom = PhotoZoom()
    @State private var pinching = false
    @State private var pinchEnded = Date.distantPast
    @State private var items: [PHAsset]
    @State private var itemIndices: [String: Int]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(library: PhotoLibrary, section: LibrarySection, initialID: String, slots: PhotoSlotFrames, screenInsets: EdgeInsets, onPage: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.library = library
        self.section = section
        self.slots = slots
        self.screenInsets = screenInsets
        self.onPage = onPage
        self.onClose = onClose
        _currentID = State(initialValue: initialID)
        let initialItems = library.items(in: section)
        _items = State(initialValue: initialItems)
        _itemIndices = State(initialValue: Dictionary(uniqueKeysWithValues: initialItems.enumerated().map { ($0.element.localIdentifier, $0.offset) }))
        if !UIAccessibility.isReduceMotionEnabled, slots.viewport.width > 0,
           let source = slots.frames[initialID], source.width > 0,
           let asset = initialItems.first(where: { $0.localIdentifier == initialID }) {
            _returningAsset = State(initialValue: asset)
            _returnFrame = State(initialValue: source)
            _returnClipFrame = State(initialValue: slots.viewport)
            _opening = State(initialValue: true)
        }
    }

    private var current: PHAsset? {
        guard let index = itemIndices[currentID], items.indices.contains(index) else { return nil }
        return items[index]
    }
    private var chromeVisible: Bool { returnDrag.height < 1 && returningAsset == nil }
    private var position: String {
        guard let index = itemIndices[currentID] else { return "" }
        return "\(index + 1) of \(items.count)"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(returningAsset == nil ? max(0, 1 - Double(returnDrag.height / 400)) : returnBackdrop).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text(section.rawValue).font(.headline)
                    Spacer()
                    Button("Done") { returnToSlot() }.disabled(isDeleting)
                }.padding(.horizontal, 20)
                    .opacity(chromeVisible ? 1 : 0)
                    .allowsHitTesting(chromeVisible)
                pager
                viewerActions
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
            }
            .padding(.top, screenInsets.top + 16)
            .padding(.bottom, screenInsets.bottom + 16)
            .padding(.leading, screenInsets.leading)
            .padding(.trailing, screenInsets.trailing)
            .opacity(returningAsset == nil ? 1 : 0)
            .disabled(isDeleting || returningAsset != nil)
            .overlay { if isDeleting { ProgressView("Deleting…").padding().background(.regularMaterial, in: Capsule()) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay {
            GeometryReader { geometry in
                if let returningAsset {
                    let origin = geometry.frame(in: .global).origin
                    AssetThumbnail(asset: returningAsset, target: CGSize(width: 1200, height: 1600))
                        .frame(width: max(1, returnFrame.width), height: max(1, returnFrame.height))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .position(x: returnFrame.midX - origin.x, y: returnFrame.midY - origin.y)
                        .mask {
                            Rectangle()
                                .frame(width: max(1, returnClipFrame.width), height: max(1, returnClipFrame.height))
                                .position(x: returnClipFrame.midX - origin.x, y: returnClipFrame.midY - origin.y)
                        }
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: currentID) { _, id in zoom = PhotoZoom(); returnDrag = .zero; onPage(id) }
        .onChange(of: pinching) { _, active in
            guard !active else { return }
            pinchEnded = Date()
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86)) {
                zoom = PhotoZoom()
            }
        }
        .onChange(of: library.reviewRevision) { _, _ in
            items = library.items(in: section)
            itemIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.localIdentifier, $0.offset) })
            if itemIndices[currentID] == nil, let first = items.first {
                currentID = first.localIdentifier
            }
        }
        .sheet(item: $playing) { VideoPlayback(asset: $0.asset) }
        .confirmationDialog("Delete from Apple Photos?", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { selection in
            Button("Delete", role: .destructive) { deleteItem(selection.asset) }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { _ in
            Text("This item will be deleted from your iPhone library and synced devices. Apple Photos normally keeps it in Recently Deleted for 30 days.")
        }
        .alert("Couldn’t delete item", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: { Text(deletionError ?? "Please try again.") }
    }

    private var viewerActions: some View {
    VStack(spacing: 16) {
    HStack(spacing: 24) {
        Button { pageBy(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
            .disabled(currentIndex == 0).accessibilityLabel("Previous item")
        Text(position).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Button { pageBy(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
            .disabled(currentIndex >= items.count - 1).accessibilityLabel("Next item")
    }
    if let current {
        Button("Return to Swipe Queue", systemImage: "arrow.uturn.backward") {
            library.restore(current)
            onClose()
        }
        .buttonStyle(.bordered)
        if section == .kept || section == .removed {
            Button("Delete", systemImage: "trash", role: .destructive) {
                confirmation = MediaSelection(asset: current)
            }
            .buttonStyle(.bordered).tint(.red)
        }
    }
    }
    }

    private var currentIndex: Int {
        itemIndices[currentID] ?? 0
    }

    private struct Page: Identifiable {
        let asset: PHAsset
        let index: Int
        var id: String { asset.localIdentifier }
    }

    private var nearbyPages: [Page] {
        let media = items
        guard !media.isEmpty else { return [] }
        let lower = max(0, currentIndex - 1)
        let upper = min(media.count - 1, currentIndex + 1)
        guard lower <= upper else { return [] }
        return (lower...upper).map { Page(asset: media[$0], index: $0) }
    }

    private var pager: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                ForEach(nearbyPages) { entry in
                    detailPage(entry.asset, size: geometry.size)
                        .frame(width: width, height: geometry.size.height)
                        .offset(x: CGFloat(entry.index - currentIndex) * width + pageDrag)
                        .allowsHitTesting(entry.index == currentIndex)
                        .accessibilityHidden(entry.index != currentIndex)
                        .transition(.identity)
                }
            }
            .frame(width: width, height: geometry.size.height)
            .clipShape(PhotoPagerVisibleArea(downwardExtension: max(0, returnDrag.height)))
            .contentShape(Rectangle())
            .onAppear {
                viewportFrame = geometry.frame(in: .global)
                animateOpening()
            }
            .onChange(of: geometry.frame(in: .global)) { _, frame in
                viewportFrame = frame
                animateOpening()
            }
            .coordinateSpace(name: "detailViewport")
            .simultaneousGesture(pageGesture(size: geometry.size))
            .overlay {
                PinchMotionSurface(active: !isDeleting && returningAsset == nil && confirmation == nil && playing == nil) { motion in
                    if motion.ended { pinching = false }
                    else {
                        pinching = true
                        pageDrag = 0
                        returnDrag = .zero
                        zoom.magnify(motion.scale, anchor: motion.anchor, in: geometry.size, translation: motion.translation)
                    }
                }
            }
            .accessibilityAction(named: Text("Reset zoom")) { withAnimation { zoom = PhotoZoom() } }
            .accessibilityAction(named: Text("Close photo viewer")) { returnToSlot() }
            .accessibilityAction(named: Text("Next item")) { pageBy(1) }
            .accessibilityAction(named: Text("Previous item")) { pageBy(-1) }
        }
    }

    private func pageGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named("detailViewport"))
            .onChanged { value in
                guard !isDeleting, returningAsset == nil, confirmation == nil, !pinching, Date().timeIntervalSince(pinchEnded) > 0.12 else { return }
                if zoom.scale > 1.01 { zoom.pan(value.translation, in: size); return }
                if value.translation.height > abs(value.translation.width) {
                    pageDrag = 0
                    returnDrag = CGSize(width: value.translation.width * 0.35, height: value.translation.height)
                    return
                }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                returnDrag = .zero
                let translation = value.translation.width
                let beyondEdge = (currentIndex == 0 && translation > 0) || (currentIndex == items.count - 1 && translation < 0)
                pageDrag = beyondEdge ? translation * 0.2 : translation
            }
            .onEnded { value in
                guard !isDeleting, returningAsset == nil, confirmation == nil, !pinching, Date().timeIntervalSince(pinchEnded) > 0.12 else { return }
                if zoom.scale > 1.01 { zoom.finishPan(); return }
                let translation = value.translation
                let predicted = value.predictedEndTranslation.width
                if translation.height > abs(translation.width),
                   translation.height > 72 || (translation.height > 20 && value.predictedEndTranslation.height > 150) {
                    returnToSlot()
                } else if abs(translation.width) > abs(translation.height),
                   abs(translation.width) > 45 || (abs(translation.width) > 20 && abs(predicted) > 130) {
                    animatePage(translation.width < 0 ? 1 : -1)
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
                        pageDrag = 0
                        returnDrag = .zero
                    }
                }
            }
    }

    private func animateOpening() {
        guard opening, !openingStarted, viewportFrame.width > 32, viewportFrame.height > 0 else { return }
        openingStarted = true
        let target = viewportFrame.insetBy(dx: 16, dy: 0)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.24), completionCriteria: .logicallyComplete) {
                returnFrame = target
                returnClipFrame = slots.viewport.union(viewportFrame)
                returnBackdrop = 1
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    opening = false
                    returningAsset = nil
                }
            }
        }
    }

    private func returnToSlot() {
        guard !isDeleting, returningAsset == nil, confirmation == nil else { return }
        guard !reduceMotion, let asset = current,
              let target = slots.frames[asset.localIdentifier], target.width > 0,
              viewportFrame.width > 0, slots.viewport.width > 0 else { onClose(); return }
        let base = viewportFrame.insetBy(dx: 16, dy: 0)
        let scale = max(0.75, 1 - returnDrag.height / 1800)
        let start = CGRect(x: base.midX - base.width * scale / 2 + returnDrag.width,
                           y: base.midY - base.height * scale / 2 + returnDrag.height,
                           width: base.width * scale, height: base.height * scale)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            returnFrame = start
            returnClipFrame = slots.viewport.union(start)
            returnBackdrop = max(0, 1 - Double(returnDrag.height / 400))
            returningAsset = asset
        }
        // Only this temporary return image changes frame. Normal pages never
        // participate in thumbnail geometry or change size while browsing.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22), completionCriteria: .logicallyComplete) {
                returnFrame = target
                returnClipFrame = slots.viewport
                returnBackdrop = 0
            } completion: { onClose() }
        }
    }

    private func animatePage(_ step: Int) {
        let next = currentIndex + step
        guard items.indices.contains(next), !isDeleting, returningAsset == nil, confirmation == nil else {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.92)) { pageDrag = 0 }
            return
        }
        // Commit immediately. The retained page IDs animate their new positions,
        // and a new drag may interrupt this spring without waiting for completion.
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.92, blendDuration: 0.08)) {
            currentID = items[next].localIdentifier
            pageDrag = 0
            returnDrag = .zero
        }
    }

    private func pageBy(_ step: Int) {
        animatePage(step)
    }

    private func detailPage(_ asset: PHAsset, size: CGSize) -> some View {
        ZStack {
            AssetThumbnail(asset: asset, target: CGSize(width: 1200, height: 1600))
                .frame(width: max(0, size.width - 32), height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .scaleEffect(asset.localIdentifier == currentID && !reduceMotion ? max(0.75, 1 - returnDrag.height / 1800) : 1)
                .offset(asset.localIdentifier == currentID && !reduceMotion ? returnDrag : .zero)
                .scaleEffect(asset.localIdentifier == currentID ? zoom.scale : 1)
                .offset(asset.localIdentifier == currentID ? zoom.offset : .zero)
            if asset.mediaType == .video {
                Button { playing = MediaSelection(asset: asset) } label: {
                    Image(systemName: "play.fill").font(.title)
                        .frame(width: 68, height: 68).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Play video")
            }
        }
    }

    private func deleteItem(_ asset: PHAsset) {
        guard !isDeleting, section == .kept || section == .removed else { return }
        isDeleting = true
        confirmation = nil
        Task { @MainActor in
            do {
                try await library.deleteReviewed([asset], from: section)
                onClose()
            } catch { deletionError = error.localizedDescription }
            isDeleting = false
        }
    }
}

private struct AlbumPicker: View {
    @ObservedObject var library: PhotoLibrary
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [PHAssetCollection] = []
    @State private var creating = false
    @State private var title = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saved = false
    @State private var savedAlbumTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Button { title = ""; creating = true } label: {
                    Label("New Album", systemImage: "plus")
                        .font(.body.weight(.medium)).foregroundStyle(.mint)
                        .padding(.vertical, 8)
                }
                Section {
                    ForEach(albums, id: \.localIdentifier) { album in
                        Button { save(to: album) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                                Text(album.localizedTitle ?? "Untitled Album").foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus").font(.caption).foregroundStyle(.tertiary)
                            }.padding(.vertical, 8)
                        }
                    }
                } header: { Text("Your albums") }
                if albums.isEmpty {
                    Text("Create an album to give this memory a home.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) } }
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    VStack(spacing: 12) {
                        if saved { Image(systemName: "checkmark").font(.title2).foregroundStyle(.mint) }
                        else { ProgressView() }
                        Text(saved ? "Added to \(savedAlbumTitle) · Kept" : "Saving…")
                            .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
        .task { albums = library.editableAlbums() }
        .alert("New Album", isPresented: $creating) {
            TextField("Album name", text: $title)
            Button("Create & Add") { save(to: nil) }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Create an album in Apple Photos and add this item.") }
        .alert("Couldn’t add to album", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
    }

    private func save(to album: PHAssetCollection?) {
        guard !isSaving else { return }
        let albumName = album?.localizedTitle ?? title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !albumName.isEmpty else { return }
        isSaving = true
        Task { @MainActor in
            do {
                if let album { try await library.add(asset, to: album) }
                else { try await library.createAlbum(named: albumName, adding: asset) }
                // Album writes must succeed before changing the review decision.
                library.decide(asset, section: .kept)
                savedAlbumTitle = albumName
                withAnimation(.easeInOut(duration: 0.2)) { saved = true }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? await Task.sleep(for: .milliseconds(650))
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct HeartFeedback: Identifiable {
    let id = UUID()
    let favorite: Bool
}

private struct HeartCelebration: View {
    let favorite: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var faded = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if favorite && !reduceMotion {
                    ForEach(0..<6) { index in
                        Image(systemName: "sparkle")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.pink.opacity(0.8))
                            .offset(x: appeared ? cos(Double(index) * .pi / 3) * 75 : 0,
                                    y: appeared ? sin(Double(index) * .pi / 3) * 75 : 0)
                    }
                }
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .font(.system(size: 76, weight: .semibold))
                    .foregroundStyle(favorite ? Color.pink : Color.mint)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            }
            Text(favorite ? "Added to Favorites" : "Favorite removed")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .scaleEffect(reduceMotion ? 1 : (appeared ? (faded && !favorite ? 0.8 : 1) : 0.35))
        .offset(y: reduceMotion ? 0 : (faded ? -32 : 0))
        .opacity(appeared && !faded ? 1 : 0)
        .task {
            withAnimation(reduceMotion ? .easeIn(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.6)) {
                appeared = true
            }
            do { try await Task.sleep(for: .milliseconds(950)) } catch { return }
            withAnimation(.easeOut(duration: 0.3)) { faded = true }
        }
    }
}

struct TabPageTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            .tracking(-0.8)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct FloatingTabGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else { fallback(content) }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content.background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}
