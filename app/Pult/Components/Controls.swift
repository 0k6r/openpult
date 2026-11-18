import SwiftUI
import UIKit
import BraviaKit

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func firm() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Round key face.
struct KeyCap: View {
    var systemImage: String?
    var text: String?
    var fill: AnyShapeStyle = AnyShapeStyle(Color.white.opacity(0.10))
    var foreground: Color = .white
    var size: CGFloat = 62

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.34, weight: .semibold))
            } else if let text {
                Text(text)
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(foreground)
        .frame(width: size, height: size)
    }
}

/// A round button that sends one IRCC key.
struct KeyButton: View {
    @Environment(RemoteModel.self) private var model
    let key: RemoteKey
    var systemImage: String? = nil
    var text: String? = nil
    let label: LocalizedStringResource
    var size: CGFloat = 62
    var fill: AnyShapeStyle = AnyShapeStyle(Color.white.opacity(0.10))

    var body: some View {
        Button {
            Haptics.tap()
            Task { await model.press(key) }
        } label: {
            KeyCap(systemImage: systemImage, text: text, fill: fill, size: size)
                .opacity(model.isAvailable(key) ? 1 : 0.35)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(label))
        .accessibilityNoCode(model.isAvailable(key))
    }
}

extension View {
    /// Tells VoiceOver that the TV profile has no code for this key (it is shown dimmed).
    func accessibilityNoCode(_ isAvailable: Bool) -> some View {
        accessibilityValue(isAvailable ? Text(verbatim: "") : Text("no code", comment: "VoiceOver value of a key the TV profile has no code for."))
    }
}

/// Fires once on touch-down, then repeats while held (after a short delay).
/// The next repeat waits for the previous command to finish, so requests never pile up.
/// Repeating stops on release, on the first failed command, after ~10 s, or when the
/// app leaves the foreground — a stuck volume repeat must never happen.
struct RepeatButton<Label: View>: View {
    let accessibilityLabel: LocalizedStringResource
    /// Pause before the first auto-repeat.
    var initialDelay: Duration = .milliseconds(400)
    /// Receives `true` for auto-repeats; returns `false` when the command failed.
    let action: (_ isRepeat: Bool) async -> Bool
    @ViewBuilder var label: () -> Label

    @Environment(\.scenePhase) private var scenePhase
    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        label()
            .scaleEffect(isPressed ? 0.92 : 1)
            .opacity(isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 3600, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                if pressing { start() } else { stop() }
            })
            .onDisappear { stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { stop() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { Task { _ = await action(false) } }
    }

    private func start() {
        guard repeatTask == nil else { return }
        isPressed = true
        Haptics.tap()
        repeatTask = Task {
            // The first command is not cancelled by a quick release: BraviaClient sends
            // it from its own queue, so a short tap always delivers exactly one key.
            guard await action(false) else { return }
            try? await Task.sleep(for: initialDelay)
            var repeats = 0
            while !Task.isCancelled, repeats < 80 {
                guard await action(true) else { return }
                repeats += 1
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stop() {
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}

struct DPadView: View {
    @Environment(RemoteModel.self) private var model
    var size: CGFloat = 220

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 8)

            arrow(.up, icon: "chevron.up", label: "Up").offset(y: -size * 0.34)
            arrow(.down, icon: "chevron.down", label: "Down").offset(y: size * 0.34)
            arrow(.left, icon: "chevron.left", label: "Left").offset(x: -size * 0.34)
            arrow(.right, icon: "chevron.right", label: "Right").offset(x: size * 0.34)

            Button {
                Haptics.firm()
                Task { await model.press(.confirm) }
            } label: {
                ZStack {
                    Circle().fill(Color.accentColor.gradient)
                    Text("OK").font(.title3.weight(.bold)).foregroundStyle(.white)
                }
                .opacity(model.isAvailable(.confirm) ? 1 : 0.35)
                .frame(width: size * 0.38, height: size * 0.38)
                .shadow(color: Color.accentColor.opacity(0.4), radius: 10)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("OK")
            .accessibilityNoCode(model.isAvailable(.confirm))
        }
        .frame(width: size, height: size)
    }

    private func arrow(_ key: RemoteKey, icon: String, label: LocalizedStringResource) -> some View {
        RepeatButton(accessibilityLabel: label, initialDelay: model.holdDelay, action: { await model.press(key, isRepeat: $0) }) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white.opacity(model.isAvailable(key) ? 0.9 : 0.3))
                .frame(width: size * 0.3, height: size * 0.3)
        }
        .accessibilityNoCode(model.isAvailable(key))
    }
}

/// Vertical +/– rocker for volume or channels.
struct RockerView: View {
    @Environment(RemoteModel.self) private var model
    let title: LocalizedStringResource
    let up: RemoteKey
    let down: RemoteKey
    let upLabel: LocalizedStringResource
    let downLabel: LocalizedStringResource
    var upIcon = "plus"
    var downIcon = "minus"

    var body: some View {
        VStack(spacing: 0) {
            RepeatButton(accessibilityLabel: upLabel, initialDelay: model.holdDelay, action: { await model.press(up, isRepeat: $0) }) {
                Image(systemName: upIcon)
                    .font(.title2.weight(.semibold))
                    .frame(width: 66, height: 56)
                    .opacity(model.isAvailable(up) ? 1 : 0.3)
            }
            .accessibilityNoCode(model.isAvailable(up))
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            RepeatButton(accessibilityLabel: downLabel, initialDelay: model.holdDelay, action: { await model.press(down, isRepeat: $0) }) {
                Image(systemName: downIcon)
                    .font(.title2.weight(.semibold))
                    .frame(width: 66, height: 56)
                    .opacity(model.isAvailable(down) ? 1 : 0.3)
            }
            .accessibilityNoCode(model.isAvailable(down))
        }
        .foregroundStyle(.white)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }
}

struct BannerView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    var edge: VerticalEdge = .top

    var body: some View {
        if let banner = model.banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? Color.orange : Color.green)
                Text(banner.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                switch banner.action {
                case .repair:
                    Button("Connect") { model.repair() }
                        .font(.subheadline.weight(.semibold))
                case .repairBlaster:
                    Button("Reconnect") {
                        model.banner = nil
                        model.repairBlaster()
                    }
                    .font(.subheadline.weight(.semibold))
                case nil:
                    EmptyView()
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .padding(edge == .top ? .top : .bottom, 6)
            .transition(.move(edge: edge == .top ? .top : .bottom).combined(with: .opacity))
            .onTapGesture { withAnimation { model.banner = nil } }
            .accessibilityElement(children: .contain)
            .task(id: banner.id) {
                AccessibilityNotification.Announcement(banner.text).post()
                // Keep actionable banners (and everything under VoiceOver) until dismissed.
                guard banner.action == nil, !voiceOverEnabled else { return }
                try? await Task.sleep(for: .seconds(banner.isError ? 6 : 2.5))
                if model.banner?.id == banner.id {
                    withAnimation { model.banner = nil }
                }
            }
        }
    }
}

struct SetupHelpSection: View {
    var body: some View {
        Section {
            HelpRow(number: 1, text: "The TV is on and connected to the same Wi‑Fi network as your iPhone.")
            HelpRow(number: 2, text: "On the TV: Settings → Network → Home Network Setup → Remote Device/Renderer → On.")
            HelpRow(number: 3, text: "In the same menu: IP Control → Authentication → Normal and Pre-Shared Key, then set a Pre-Shared Key, for example, 0000.")
            HelpRow(number: 4, text: "To turn on the TV from your phone: Settings → Network → Remote Start → On.")
        } header: {
            Text("TV setup")
        } footer: {
            Text("Menu names may differ slightly depending on the TV firmware.")
        }
    }
}

private struct HelpRow: View {
    let number: Int
    let text: LocalizedStringResource

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number, format: .number)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
