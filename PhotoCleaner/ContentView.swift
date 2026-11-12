import SwiftUI

private enum SwipeDirection {
    case left, right, up, down

    var destination: CGSize {
        switch self {
        case .left: return CGSize(width: -900, height: 0)
        case .right: return CGSize(width: 900, height: 0)
        case .up: return CGSize(width: 0, height: -1200)
        case .down: return CGSize(width: 0, height: 1200)
        }
    }
}

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGSize = .zero
    @State private var cardIndex = 0
    @State private var isDismissing = false
    @State private var didDoubleTap = false

    private let cards: [(title: String, subtitle: String, symbol: String, colors: [Color])] = [
        ("Find your flow", "A little movement. A new perspective.", "water.waves", [.cyan, .blue, .indigo]),
        ("Take the scenic route", "Make room for a little wonder.", "mountain.2.fill", [.mint, .teal, .blue]),
        ("Chase the light", "Good things are on the horizon.", "sun.horizon.fill", [.orange, .pink, .purple]),
        ("Stay curious", "Your next favorite moment is waiting.", "sparkles", [.pink, .purple, .indigo])
    ]

    private var revealProgress: CGFloat {
        min(max(abs(offset.width), abs(offset.height)) / 240, 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let cardHeight = min(440.0, max(180.0, geometry.size.height * 0.54))
            VStack(spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PLAY / EXPLORE").font(.caption2.weight(.bold)).tracking(3).foregroundStyle(.mint)
                        Text("Go your own way.").font(.largeTitle.bold()).tracking(-1)
                    }
                    Spacer()
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title2).foregroundStyle(.mint)
                }
                Text("Swipe up, down, left, or right.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
                cardStack
                .frame(height: cardHeight)
                .zIndex(1)
                Spacer(minLength: 0)

            }
            .padding(24)
            .frame(maxWidth: 540).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.09).ignoresSafeArea())
        .foregroundStyle(.white)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            swipeTab
                .padding(.bottom, 8)
                .padding(.top, 12)
        }
        .preferredColorScheme(.dark)
    }

    private var cardStack: some View {
        ZStack {
            ForEach(Array((cardIndex...cardIndex + 2).reversed()), id: \.self) { index in
                interactiveCard(at: index)
            }
        }
    }

    private func positionedCard(at index: Int) -> some View {
        let depth = index - cardIndex
        let isFront = depth == 0
        let scale: CGFloat = isFront ? 1 : 1 - CGFloat(depth) * 0.05 + revealProgress * 0.05
        let verticalOffset: CGFloat = isFront ? 0 : CGFloat(depth) * 14 - revealProgress * 14
        let opacity: Double = isFront ? 1 : 1 - Double(depth) * 0.15 + Double(revealProgress) * 0.15
        let angle: Double = isFront && !reduceMotion ? Double(offset.width / 35) : 0

        return card(at: index)
            .overlay {
                RoundedRectangle(cornerRadius: 32)
                    .strokeBorder(Color.white.opacity(didDoubleTap && isFront ? 0.65 : 0), lineWidth: 2)
            }
            .scaleEffect(scale)
            .offset(y: verticalOffset)
            .opacity(opacity)
            .offset(isFront ? offset : CGSize.zero)
            .rotationEffect(.degrees(angle))
            .zIndex(Double(3 - depth))
    }

    private func interactiveCard(at index: Int) -> some View {
        positionedCard(at: index)
            .allowsHitTesting(index == cardIndex && !isDismissing)
            .accessibilityHidden(index != cardIndex)
            .gesture(swipeGesture)
            .simultaneousGesture(TapGesture(count: 2).onEnded { registerDoubleTap() })
            .accessibilityLabel("\(cards[index % cards.count].title). Card \(index + 1)")
            .accessibilityHint("Swipe in any direction to advance.")
            .accessibilityAction(named: Text("Swipe left")) { dismiss(.left) }
            .accessibilityAction(named: Text("Swipe right")) { dismiss(.right) }
            .accessibilityAction(named: Text("Swipe up")) { dismiss(.up) }
            .accessibilityAction(named: Text("Swipe down")) { dismiss(.down) }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isDismissing else { return }
                offset = value.translation
            }
            .onEnded { value in
                guard !isDismissing else { return }
                let actual = value.translation
                let predicted = value.predictedEndTranslation
                let distance = max(abs(actual.width), abs(actual.height))
                let predictedDistance = max(abs(predicted.width), abs(predicted.height))
                if distance > 90 {
                    dismiss(direction(for: actual))
                } else if distance > 25 && predictedDistance > 180 {
                    dismiss(direction(for: predicted))
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
                        offset = .zero
                    }
                }
            }
    }

    private var swipeTab: some View {
        Button(action: {}) {
            Label("Swipe", systemImage: "hand.draw.fill")
        }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.mint)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .modifier(FloatingTabGlass())
            .accessibilityAddTraits(.isSelected)
            .accessibilityLabel("Swipe tab, selected")
    }

    private func card(at index: Int) -> some View {
        let item = cards[index % cards.count]
        return ZStack {
            RoundedRectangle(cornerRadius: 32)
                .fill(LinearGradient(colors: item.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(.white.opacity(0.08)).frame(width: 240, height: 240).offset(x: 100, y: -110)
            Image(systemName: item.symbol)
                .font(.system(size: 110, weight: .ultraLight)).foregroundStyle(.white.opacity(0.8))
                .offset(y: -30)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("THE EVERYDAY COLLECTION").font(.system(size: 9, weight: .bold)).tracking(2)
                    Spacer()
                    Text(String(format: "%02d", index + 1)).font(.caption.monospaced())
                }
                Spacer()
                Text(item.title).font(.system(size: 32, weight: .bold, design: .rounded))
                Text(item.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.8))
            }.padding(26)
        }
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 12)
    }

    private func registerDoubleTap() {
        guard !isDismissing, offset == .zero else { return }
        didDoubleTap = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            didDoubleTap = false
        }
    }

    private func direction(for translation: CGSize) -> SwipeDirection {
        if abs(translation.width) > abs(translation.height) {
            return translation.width < 0 ? .left : .right
        }
        return translation.height < 0 ? .up : .down
    }

    private func dismiss(_ direction: SwipeDirection) {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.92), completionCriteria: .removed) {
            offset = direction.destination
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cardIndex += 1
                offset = .zero
                didDoubleTap = false
                isDismissing = false
            }
        }
    }
}

private struct FloatingTabGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}
