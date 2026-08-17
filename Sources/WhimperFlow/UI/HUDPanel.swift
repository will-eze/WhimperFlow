import AppKit
import SwiftUI
import Combine

/// Observable model driving the floating HUD: state, waveform, live transcript.
@MainActor
final class HUDModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: HUDModel.barCount)
    @Published var partialText = ""

    static let barCount = 27

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        levels = Array(repeating: 0, count: HUDModel.barCount)
        partialText = ""
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
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
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
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
        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 64
        )
        setFrameOrigin(origin)
    }
}

// MARK: - SwiftUI content

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 6) {
            if !model.partialText.isEmpty {
                Text(model.partialText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                statusDot
                waveform
                stateLabel
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: model.partialText.isEmpty)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 9, height: 9)
            .opacity(model.state.isListening ? 1 : 0.85)
    }

    private var dotColor: Color {
        switch model.state {
        case .listening: return .red
        case .processing: return .orange
        case .error: return .yellow
        case .idle: return .gray
        }
    }

    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor.opacity(0.9))
                    .frame(width: 2.5, height: 4 + CGFloat(level) * 22)
            }
        }
        .frame(height: 28)
        .animation(.linear(duration: 0.05), value: model.levels)
    }

    private var stateLabel: some View {
        Group {
            switch model.state {
            case .listening(let handsFree):
                Text(handsFree ? "Listening (hands-free)" : "Listening…")
            case .processing:
                Text("Processing…")
            case .error(let message):
                Text(message).lineLimit(1)
            case .idle:
                Text("")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(minWidth: 60, alignment: .leading)
    }
}
