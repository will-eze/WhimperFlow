import AppKit
import SwiftUI
import Combine

/// Observable model driving the floating HUD: state, waveform, live transcript.
@MainActor
final class HUDModel: ObservableObject {
    @Published var state: DictationState = .idle {
        didSet {
            if state.isListening, !oldValue.isListening { startedAt = Date() }
        }
    }
    @Published var levels: [Float] = Array(repeating: 0, count: HUDModel.barCount)
    @Published var partialText = ""
    /// Apple's on-device fallback produced some of this dictation's text.
    @Published var usedFallback = false
    /// The engine this dictation starts on ("Parakeet" or "Apple").
    @Published var engine = "Parakeet"
    @Published private(set) var startedAt = Date()

    static let barCount = 27

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        levels = Array(repeating: 0, count: HUDModel.barCount)
        partialText = ""
        usedFallback = false
    }
}

/// Borderless, non-activating floating panel pinned near the bottom of the
/// screen while dictating.
@MainActor
final class HUDPanel: NSPanel {
    private let model: HUDModel

    init(model: HUDModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 110),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = NSHostingView(rootView: HUDView(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        guard !isVisible || alphaValue < 1 else { return }
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 48))
    }
}

// MARK: - SwiftUI content

/// A dark pill that reads the same over any app: a state mark, a mirrored
/// waveform that fades as it ages, the elapsed time and the engine.
struct HUDView: View {
    @ObservedObject var model: HUDModel
    @State private var appeared = false

    private static let ink = Color(red: 0.07, green: 0.07, blue: 0.08)
    private static let signal = Color(red: 1.0, green: 0.27, blue: 0.23)

    var body: some View {
        VStack(spacing: 8) {
            if !model.partialText.isEmpty {
                Text(model.partialText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Self.ink.opacity(0.88), in: Capsule())
                    .frame(maxWidth: 400)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
        .animation(.easeOut(duration: 0.15), value: model.partialText.isEmpty)
        .environment(\.colorScheme, .dark)
    }

    private var pill: some View {
        HStack(spacing: 14) {
            mark
            waveform
            trailing
                .frame(minWidth: 124, alignment: .leading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 46)
        .background(Self.ink.opacity(0.92), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .scaleEffect(appeared ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { appeared = true }
        }
    }

    // MARK: - State mark

    @ViewBuilder
    private var mark: some View {
        switch model.state {
        case .listening:
            PulsingDot(color: Self.signal)
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
                .frame(width: 14, height: 14)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 13))
        case .idle:
            Image(systemName: "checkmark")
                .foregroundStyle(.white.opacity(0.8))
                .font(.system(size: 12, weight: .bold))
        }
    }

    // MARK: - Waveform

    private var waveform: some View {
        let count = model.levels.count
        let tint: Color = model.state.isListening ? .white : .white.opacity(0.35)
        return HStack(alignment: .center, spacing: 3) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { index, level in
                // Newest on the right at full strength; older bars fade.
                let age = Double(count - 1 - index) / Double(max(count - 1, 1))
                Capsule()
                    .fill(tint.opacity(1 - age * 0.7))
                    .frame(width: 3, height: 3 + CGFloat(min(max(level, 0), 1)) * 26)
            }
        }
        .frame(height: 30)
        .animation(.linear(duration: 0.05), value: model.levels)
    }

    // MARK: - Trailing text

    @ViewBuilder
    private var trailing: some View {
        switch model.state {
        case .listening(let handsFree):
            HStack(spacing: 8) {
                TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                    Text(elapsed(at: context.date))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                }
                tag(handsFree ? "Hands-free" : model.engine,
                    color: model.engine == "Apple" && !handsFree ? .orange : .white.opacity(0.6))
            }
        case .processing:
            Text("Typing…").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        case .error(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
        case .idle:
            if model.usedFallback {
                tag("Typed by Apple", color: .orange)
                    .help("The server didn't answer, so Apple's on-device recogniser typed this.")
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(model.startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The recording mark: a solid dot with a ring breathing out of it.
private struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(pulse ? 0 : 0.6), lineWidth: 2)
                .frame(width: pulse ? 22 : 10, height: pulse ? 22 : 10)
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
