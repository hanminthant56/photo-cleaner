import SwiftUI
import Photos
import AVKit
import Combine

private enum LibrarySection: String, CaseIterable {
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
    @Published var decisions: [String: String]
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var pending: [PHAsset] = []
    private let storageKey = "PhotoCleaner.decisions.v1"

    init() {
        decisions = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }

    func items(in section: LibrarySection) -> [PHAsset] {
        if section == .all { return pending }
        return assets.filter { decisions[$0.localIdentifier] == section.rawValue }
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasAccess else { assets = []; pending = []; return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var loaded: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in loaded.append(asset) }
        assets = loaded
        rebuildQueue()
    }

    func decide(_ asset: PHAsset, section: LibrarySection) {
        decisions[asset.localIdentifier] = section.rawValue
        save()
    }

    func restore(_ asset: PHAsset) {
        decisions.removeValue(forKey: asset.localIdentifier)
        save()
    }

    private func rebuildQueue() {
        pending = assets.filter { decisions[$0.localIdentifier] == nil }
    }

    private func save() {
        rebuildQueue()
        UserDefaults.standard.set(decisions, forKey: storageKey)
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
    @State private var doubleTapped = false

    private var progress: CGFloat { min(abs(offset.width) / 180, 1) }
    private var removing: Bool { offset.width < 0 }

    var body: some View {
        VStack(spacing: 12) {
            header
            if library.hasAccess {
                if library.authorization == .limited { limitedAccessNotice }
                if section == .all {
                    swipeArea
                } else {
                    collection
                }
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
        .task { library.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !isDismissing { library.refresh() }
        }
        .sheet(item: $playing) { selection in VideoPlayback(asset: selection.asset) }
        .sheet(item: $inspected) { selection in
            MediaDetail(asset: selection.asset) {
                library.restore(selection.asset)
                inspected = nil
            }
        }
    }

    private var header: some View {
        HStack {
            TabPageTitle(title: "Swipe")
            Spacer()
            Menu {
                ForEach(LibrarySection.allCases, id: \.self) { item in
                    Button {
                        guard !isDismissing else { return }
                        section = item
                        offset = .zero
                    } label: {
                        Label(item.rawValue, systemImage: section == item ? "checkmark" : item.symbol)
                    }
                }
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
        .padding(.horizontal, 8)
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
            let height = min(width * 1.4, max(180, geometry.size.height - 48))
            VStack(spacing: 14) {
                Spacer(minLength: 8)
                if !library.pending.isEmpty {
                    deck(size: CGSize(width: width, height: height))
                    Text("Left to remove · Right to keep")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
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
        .accessibilityElement(children: .contain)
    }

    private func mediaCard(asset: PHAsset, depth: Int, size: CGSize) -> some View {
        let front = depth == 0
        let scale: CGFloat = front ? 1 : 1 - CGFloat(depth) * 0.035 + progress * 0.035
        let lift: CGFloat = front ? 0 : CGFloat(depth) * 10 - progress * 10
        return MediaCard(asset: asset, size: size) { playing = MediaSelection(asset: asset) }
            .overlay(alignment: removing ? .topTrailing : .topLeading) {
                if front { decisionBadge.opacity(Double(progress)).padding(20) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(doubleTapped && front ? Color.white.opacity(0.7) : .clear, lineWidth: 2)
            }
            .scaleEffect(scale)
            .offset(y: lift)
            .offset(front ? offset : .zero)
            .rotationEffect(.degrees(front && !reduceMotion ? Double(offset.width / 45) : 0))
            .zIndex(Double(3 - depth))
            .allowsHitTesting(front && !isDismissing)
            .accessibilityHidden(!front)
            .gesture(swipeGesture(for: asset, size: size))
            .simultaneousGesture(TapGesture(count: 2).onEnded { acknowledgeDoubleTap() })
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
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isDismissing else { return }
                offset = value.translation
            }
            .onEnded { value in
                guard !isDismissing else { return }
                let actual = value.translation
                let projected = value.predictedEndTranslation
                let horizontal = abs(actual.width) > abs(actual.height)
                let crossed = abs(actual.width) > 90 || (abs(actual.width) > 25 && abs(projected.width) > 180)
                if horizontal && crossed {
                    decide(asset, keep: actual.width > 0, size: size)
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)) { offset = .zero }
                }
            }
    }

    private func decide(_ asset: PHAsset, keep: Bool, size: CGSize) {
        guard !isDismissing else { return }
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
                doubleTapped = false
            }
        }
    }

    private var collection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(section.rawValue).font(.title2.weight(.semibold))
                if section == .removed {
                    Text("Only set aside in this app. Originals are still in your iPhone library.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                let items = library.items(in: section)
                if items.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: section.symbol)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(items, id: \.localIdentifier) { asset in
                            Button { inspected = MediaSelection(asset: asset) } label: {
                                AssetThumbnail(asset: asset, target: CGSize(width: 400, height: 480))
                                    .frame(height: 210).frame(maxWidth: .infinity)
                                    .background(.white.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay(alignment: .bottomTrailing) {
                                        if asset.mediaType == .video {
                                            Image(systemName: "play.circle.fill").font(.title).padding(10)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(asset.mediaType == .video ? "Video, view item" : "Photo, view item")
                        }
                    }
                }
            }.padding(.top, 12)
        }
    }

    private var swipeTab: some View {
        Button { if !isDismissing { section = .all } } label: {
            Label("Swipe", systemImage: "hand.draw.fill")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 22).frame(height: 48)
        }
        .buttonStyle(.plain).foregroundStyle(.mint)
        .modifier(FloatingTabGlass())
        .accessibilityAddTraits(.isSelected)
    }

    private func acknowledgeDoubleTap() {
        guard !isDismissing, offset == .zero else { return }
        doubleTapped = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            doubleTapped = false
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

private struct MediaSelection: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

private struct MediaCard: View {
    let asset: PHAsset
    let size: CGSize
    let play: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.10, blue: 0.14)
            AssetThumbnail(asset: asset, target: CGSize(width: size.width * 2, height: size.height * 2))
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
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .accessibilityLabel(asset.mediaType == .video ? "Video" : "Photo")
    }
}

private struct AssetThumbnail: View {
    let asset: PHAsset
    let target: CGSize
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Label("Unable to load from iCloud", systemImage: "icloud.slash")
                    .font(.caption).foregroundStyle(.secondary).padding()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: asset.localIdentifier) { await load() }
    }

    private func load() async {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let result: UIImage? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                continuation.resume(returning: image)
            }
        }
        image = result
        failed = result == nil
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

private struct MediaDetail: View {
    let asset: PHAsset
    let restore: () -> Void
    @State private var playing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                AssetThumbnail(asset: asset, target: CGSize(width: 1200, height: 1600))
                if asset.mediaType == .video {
                    Button("Play video", systemImage: "play.fill") { playing = true }
                }
                Button("Return to Swipe Queue", action: restore).buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle(asset.mediaType == .video ? "Video" : "Photo")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $playing) { VideoPlayback(asset: asset) }
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
