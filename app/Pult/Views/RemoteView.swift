import SwiftUI
import BraviaKit

struct RemoteView: View {
    private enum Sheet: String, Identifiable {
        case numbers, keyboard, apps, inputs, blaster, learn, database
        var id: String { rawValue }
    }

    @Environment(RemoteModel.self) private var model
    @State private var sheet: Sheet?

    var body: some View {
        // Prefer a layout that fits without scrolling: a scrolling remote steals
        // vertical drags from hold-to-repeat buttons. Small screens fall back to scrolling.
        ViewThatFits(in: .vertical) {
            content(dpad: 220, spacing: 14)
            content(dpad: 204, spacing: 12)
            content(dpad: 184, spacing: 10)
            ScrollView {
                content(dpad: 184, spacing: 10)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.08, green: 0.10, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .overlay(alignment: .top) {
            if sheet == nil { BannerView(edge: .top) }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .numbers: NumpadSheet()
                case .keyboard: TextInputSheet()
                case .apps: AppsSheet()
                case .inputs: InputsSheet()
                case .blaster: BlasterInfoSheet()
                case .learn: NavigationStack { LearnRemoteView(mode: .editCurrent) }
                case .database:
                    NavigationStack {
                        ProfileDatabaseView()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { self.sheet = nil }
                                }
                            }
                    }
                }
            }
            // At the bottom so it never covers the sheet's Close button or text field.
            .overlay(alignment: .bottom) { BannerView(edge: .bottom) }
            .preferredColorScheme(.dark)
        }
        .task { await model.refresh() }
    }

    private func content(dpad: CGFloat, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            header
            topRow
            DPadView(size: dpad)
            navigationRow
            rockerRow
            mediaRow
            colorRow
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isInfrared ? (model.infrared.remote?.displayName ?? String(localized: "IR Bridge")) : (model.tv?.modelName ?? String(localized: "TV")))
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Menu {
                if model.isInfrared {
                    Button {
                        sheet = .blaster
                    } label: {
                        Label("Bridge & Aiming", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button {
                        sheet = .learn
                    } label: {
                        Label("Learn Buttons", systemImage: "dot.radiowaves.forward")
                    }
                    Button {
                        model.chooseTV()
                    } label: {
                        Label("Change TV", systemImage: "tv")
                    }
                    Button {
                        sheet = .database
                    } label: {
                        Label("TV Codes", systemImage: "square.stack.3d.down.right")
                    }
                    if let remote = model.infrared.remote {
                        ShareLink(item: RemoteExport(remote: remote), preview: SharePreview(remote.displayName)) {
                            Label("Share Remote", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        model.useNetwork()
                    } label: {
                        Label("Use Wi‑Fi", systemImage: "wifi")
                    }
                } else {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await model.reloadKeyCodes() }
                    } label: {
                        Label("Reload Button Codes", systemImage: "keyboard")
                    }
                    Button {
                        model.repair()
                    } label: {
                        Label("Reconnect", systemImage: "key")
                    }
                    Button {
                        model.useInfrared()
                    } label: {
                        Label("Use IR Bridge", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button(role: .destructive) {
                        model.forgetTV()
                    } label: {
                        Label("Choose Another TV", systemImage: "tv")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .padding(.top, 4)
    }

    private var topRow: some View {
        HStack {
            Button {
                Haptics.firm()
                Task { await model.togglePower() }
            } label: {
                ZStack {
                    KeyCap(systemImage: "power", fill: AnyShapeStyle(Color.red.gradient))
                        .opacity(model.isAvailable(.power) ? 1 : 0.35)
                    if model.isPowerBusy {
                        ProgressView().tint(.white).scaleEffect(1.3)
                    }
                }
            }
            .buttonStyle(PressableStyle())
            .disabled(model.isPowerBusy)
            .accessibilityLabel("Power")
            .accessibilityNoCode(model.isAvailable(.power))
            .accessibilityActions {
                if model.isInfrared && model.infrared.isAvailable(.wakeUp) {
                    Button("Turn On") { Task { await model.press(.wakeUp) } }
                }
                if model.isInfrared && model.infrared.isAvailable(.powerOff) {
                    Button("Turn Off") { Task { await model.press(.powerOff) } }
                }
            }
            .contextMenu {
                // Over IR the TV state is unknown: offer explicit codes besides the toggle, when the TV has them.
                if model.isInfrared && model.infrared.isAvailable(.wakeUp) {
                    Button {
                        Task { await model.press(.wakeUp) }
                    } label: {
                        Label("Turn On", systemImage: "power")
                    }
                }
                if model.isInfrared && model.infrared.isAvailable(.powerOff) {
                    Button {
                        Task { await model.press(.powerOff) }
                    } label: {
                        Label("Turn Off", systemImage: "moon")
                    }
                }
            }

            Spacer()
            KeyButton(key: .input, systemImage: "arrow.right.square", label: "Input")
            Spacer()
            KeyButton(key: .options, systemImage: "slider.horizontal.3", label: "Action Menu")
        }
        .padding(.horizontal, 12)
    }

    private var navigationRow: some View {
        HStack {
            KeyButton(key: .back, systemImage: "arrow.uturn.backward", label: "Back")
            Spacer()
            KeyButton(key: .home, systemImage: "house.fill", label: "Home")
            Spacer()
            KeyButton(key: .display, systemImage: "info", label: "Info")
        }
        .padding(.horizontal, 12)
    }

    private var rockerRow: some View {
        HStack {
            RockerView(title: "VOL", up: .volumeUp, down: .volumeDown, upLabel: "Volume Up", downLabel: "Volume Down")
            Spacer()
            VStack(spacing: 12) {
                KeyButton(key: .mute, systemImage: "speaker.slash.fill", label: "Mute", size: 56)
                KeyButton(key: .subtitles, systemImage: "captions.bubble", label: "Subtitles", size: 56)
            }
            Spacer()
            RockerView(title: "CH", up: .channelUp, down: .channelDown, upLabel: "Next Channel", downLabel: "Previous Channel",
                       upIcon: "chevron.up", downIcon: "chevron.down")
        }
        .padding(.horizontal, 12)
    }

    private var mediaRow: some View {
        let keys: [(RemoteKey, String, LocalizedStringResource)] = [
            (.previous, "backward.end.fill", "Previous"),
            (.rewind, "backward.fill", "Rewind"),
            (.play, "play.fill", "Play"),
            (.pause, "pause.fill", "Pause"),
            (.stop, "stop.fill", "Stop"),
            (.forward, "forward.fill", "Fast Forward"),
            (.next, "forward.end.fill", "Next"),
        ]
        return HStack(spacing: 0) {
            ForEach(keys, id: \.0) { key, icon, label in
                KeyButton(key: key, systemImage: icon, label: label, size: 42)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var colorRow: some View {
        // VoiceOver adds "button" itself, so the label is just the color.
        let keys: [(RemoteKey, Color, LocalizedStringResource)] = [
            (.red, .red, "Red"),
            (.green, .green, "Green"),
            (.yellow, .yellow, "Yellow"),
            (.blue, .blue, "Blue"),
        ]
        return HStack(spacing: 14) {
            ForEach(keys, id: \.0) { key, color, label in
                Button {
                    Haptics.tap()
                    Task { await model.press(key) }
                } label: {
                    Capsule()
                        .fill(color.opacity(model.isAvailable(key) ? 0.85 : 0.25))
                        .frame(height: 24)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Text(label))
                .accessibilityNoCode(model.isAvailable(key))
            }
        }
        .padding(.horizontal, 8)
    }

    private var bottomBar: some View {
        let items: [(Sheet, String, LocalizedStringResource)] = model.isInfrared
            ? [
                (.numbers, "number", "Numbers"),
                (.inputs, "cable.connector", "Inputs"),
                (.blaster, "dot.radiowaves.left.and.right", "Bridge"),
            ]
            : [
                (.numbers, "number", "Numbers"),
                (.keyboard, "keyboard", "Text"),
                (.apps, "square.grid.2x2", "Apps"),
                (.inputs, "cable.connector", "Inputs"),
            ]
        return HStack(spacing: 0) {
            ForEach(items, id: \.0) { item, icon, title in
                Button {
                    Haptics.tap()
                    sheet = item
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon).font(.title3)
                        Text(title).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.white.opacity(0.9))
                .accessibilityLabel(Text(title))
            }
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    // MARK: Status

    private var statusColor: Color {
        if model.isInfrared {
            let blaster = model.blaster
            if blaster.needsRepair || [.poweredOff, .unauthorized, .unsupported].contains(blaster.availability) {
                return .red
            }
            switch blaster.connection {
            case .ready: return blaster.status?.isBatteryLow == true ? .orange : .green
            case .connecting: return .gray
            case .idle: return .orange
            }
        }
        switch model.power {
        case .on: return .green
        case .standby: return .orange
        case .offline: return .red
        case .unknown: return .gray
        }
    }

    private var statusText: String {
        if model.isInfrared {
            return blasterStatusText
        }
        switch model.power {
        case .on: return String(localized: "On", comment: "TV power status.")
        case .standby: return String(localized: "Standby", comment: "TV power status.")
        case .offline: return String(localized: "Offline", comment: "TV power status: the TV does not answer.")
        case .unknown: return String(localized: "Checking…", comment: "TV power status.")
        }
    }

    private var blasterStatusText: String {
        let blaster = model.blaster
        if blaster.needsRepair { return String(localized: "Needs reconnecting", comment: "Bridge status.") }
        switch blaster.availability {
        case .poweredOff: return String(localized: "Bluetooth is off", comment: "Bridge status.")
        case .unauthorized: return String(localized: "No Bluetooth access", comment: "Bridge status.")
        case .unsupported: return String(localized: "Bluetooth unavailable", comment: "Bridge status.")
        case .unknown, .poweredOn: break
        }
        let text: String
        switch blaster.connection {
        case .ready: text = String(localized: "Connected", comment: "Bridge status (the bridge is feminine in Russian).")
        case .connecting: text = String(localized: "Connecting…", comment: "Bridge status.")
        case .idle: text = String(localized: "Idle", comment: "Bridge status: disconnected, connects on the next key press.")
        }
        if blaster.status?.isBatteryLow == true {
            return String(localized: "\(text) · batteries low", comment: "Bridge status line. %@ is the connection status.")
        } else if let percent = blaster.batteryPercent {
            return String(
                localized: "\(text) · batteries \(percent.formatted(.percent))",
                comment: "Bridge status line. The first %@ is the connection status, the second the battery level, e.g. 80%."
            )
        }
        return text
    }
}
