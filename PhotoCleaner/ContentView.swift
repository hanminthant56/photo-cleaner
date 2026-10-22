import SwiftUI

private enum SwipeDirection: String, CaseIterable {
    case left = "Left", right = "Right", up = "Up", down = "Down"

    var symbol: String {
        switch self {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        }
    }

    var color: Color {
        switch self {
        case .left: return .pink
        case .right: return .mint
        case .up: return .cyan
        case .down: return .orange
        }
    }

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
    @State private var lastDirection: SwipeDirection?
    @State private var isDismissing = false

    private let cards: [(title: String, subtitle: String, symbol: String, colors: [Color])] = [
        ("Find your flow", "A little movement. A new perspective.", "water.waves", [.cyan, .blue, .indigo]),
        ("Take the scenic route", "Make room for a little wonder.", "mountain.2.fill", [.mint, .teal, .blue]),
        ("Chase the light", "Good things are on the horizon.", "sun.horizon.fill", [.orange, .pink, .purple]),
        ("Stay curious", "Your next favorite moment is waiting.", "sparkles", [.pink, .purple, .indigo])
    ]

    private var activeDirection: SwipeDirection? {
        guard max(abs(offset.width), abs(offset.height)) > 18 else { return nil }
        return direction(for: offset)
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
                Text("One card. Four directions. Give it a swipe.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
                ZStack {
                    card(at: cardIndex + 1)
                        .scaleEffect(0.93).offset(y: 15).opacity(0.5)
                    card(at: cardIndex)
                        .overlay(alignment: .topLeading) {
                            if let direction = activeDirection {
                                Label(direction.rawValue.uppercased(), systemImage: direction.symbol)
                                    .font(.headline).padding(14)
                                    .background(direction.color, in: Capsule())
                                    .foregroundStyle(.black).padding(22)
                            }
                        }
                        .offset(offset)
                        .rotationEffect(.degrees(Double(offset.width / 28)))
                        .gesture(DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                guard !isDismissing else { return }
                                offset = value.translation
                            }
                            .onEnded { value in
                                guard !isDismissing else { return }
                                let actual = value.translation
                                let predicted = value.predictedEndTranslation
                                if max(abs(actual.width), abs(actual.height)) > 90 {
                                    dismiss(direction(for: actual))
                                } else if max(abs(actual.width), abs(actual.height)) > 25 && max(abs(predicted.width), abs(predicted.height)) > 180 {
                                    dismiss(direction(for: predicted))
                                } else {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { offset = .zero }
                                }
                            })
                        .accessibilityLabel("\(cards[cardIndex % cards.count].title). Card \(cardIndex + 1)")
                        .accessibilityHint("Use the direction buttons below to move this card.")
                }
                .frame(height: cardHeight)
                .zIndex(1)
                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Circle().fill(lastDirection?.color ?? .mint).frame(width: 6, height: 6)
                    Text(lastDirection.map { "Swiped \($0.rawValue.lowercased()) · Keep exploring" } ?? "Pick a direction to get started")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                HStack(spacing: 16) {
                    ForEach(SwipeDirection.allCases, id: \.self) { direction in
                        Button { dismiss(direction) } label: {
                            Image(systemName: direction.symbol)
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(direction.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                                .foregroundStyle(direction.color)
                        }
                        .accessibilityLabel("Swipe \(direction.rawValue.lowercased())")
                        .disabled(isDismissing)
                    }
                }
                Text("SWIPE ANYWHERE. KEEP MOVING.")
                    .font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 540).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.09).ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
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

    private func direction(for translation: CGSize) -> SwipeDirection {
        if abs(translation.width) > abs(translation.height) {
            return translation.width < 0 ? .left : .right
        }
        return translation.height < 0 ? .up : .down
    }

    private func dismiss(_ direction: SwipeDirection) {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.24)) {
            offset = direction.destination
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 250))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cardIndex += 1
                offset = .zero
                lastDirection = direction
                isDismissing = false
            }
        }
    }
}
