import SwiftUI

/// The updater's one piece of interface: a pill in the window's corner, there only while it has
/// something to say. Its shape follows what it says, and the words change in place.
struct UpdatePill: View {
    let updater: Updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if updater.pillShown && updater.phase != .idle {
                pill
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: 14).combined(with: .scale(scale: 0.96, anchor: .bottomTrailing))
                            .combined(with: .opacity)
                            .animation(.spring(duration: 0.42, bounce: 0.18)),
                        removal: .scale(scale: 0.97, anchor: .bottomTrailing).combined(with: .opacity)
                            .animation(.easeOut(duration: 0.16))))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.42, bounce: 0.18),
                   value: updater.pillShown && updater.phase != .idle)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            content
                .id(kind)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.leading, 14)
        .padding(.trailing, hasButtons ? 6 : 16)
        .frame(height: 38)
        .modifier(PillSurface(tint: tint))
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.42, bounce: 0.18), value: kind)
        .onHover { updater.hovering = $0 }
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .checking:
            ProgressView().controlSize(.small)
            Text("Checking for updates")
        case let .downloading(v):
            ProgressView().controlSize(.small)
            Text("Downloading Super Gloss \(v)")
        case let .ready(v):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(tint)
            Text("Super Gloss \(v) is ready").foregroundStyle(tint)
            PillButton(title: "Relaunch", tint: tint) { updater.relaunch() }
                .help("Opens the new version on the word you're reading")
            CloseButton { updater.dismiss() }
                .help("Later: it goes in by itself while Super Gloss is out of sight, or when you quit")
        case let .available(v, page):
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 17)).foregroundStyle(tint)
            Text("Super Gloss \(v) is out")
            PillButton(title: "Download", tint: tint) { NSWorkspace.shared.open(page) }
                .help("Super Gloss can't replace itself where it is; move it to Applications to update in place")
            CloseButton { updater.dismiss() }
        case .current:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(tint)
            Text("Super Gloss is up to date")
        case let .failed(message):
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 17)).foregroundStyle(tint)
            Text(message)
            CloseButton { updater.dismiss() }
        case let .updated(v, page):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(tint)
            Text("Updated to \(v)").foregroundStyle(tint)
            PillButton(title: "What's New", tint: tint) {
                NSWorkspace.shared.open(page)
                updater.dismiss()
            }
            CloseButton { updater.dismiss() }
        case .idle:
            EmptyView()
        }
    }

    /// Changes of wording, not of detail (the version), re-run the transition.
    private var kind: Int {
        switch updater.phase {
        case .idle: 0
        case .checking: 1
        case .downloading: 2
        case .ready: 3
        case .available: 4
        case .current: 5
        case .failed: 6
        case .updated: 7
        }
    }

    private var hasButtons: Bool {
        switch updater.phase {
        case .ready, .available, .failed, .updated: true
        default: false
        }
    }

    private var tint: Color {
        switch updater.phase {
        case .ready, .updated, .current: .green
        case .failed: .orange
        default: .blue
        }
    }
}

/// Glass, lightly tinted with what the pill is saying; a material where glass isn't available.
struct PillSurface: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint.opacity(0.10)), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .background(tint.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        }
    }
}

private struct PillButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(tint.opacity(hover ? 0.22 : 0.15), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { hover = $0 }
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.primary.opacity(hover ? 0.11 : 0.06), in: Circle())
                .padding(7)
                .contentShape(Rectangle())
                .padding(-7)
        }
        .buttonStyle(Pressable())
        .onHover { hover = $0 }
        .accessibilityLabel("Close")
    }
}

/// A press you can feel: the control gives a little under the pointer.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
