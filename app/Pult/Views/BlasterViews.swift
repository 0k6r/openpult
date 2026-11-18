import SwiftUI
import BraviaKit

/// First-time setup of the «OpenPult» bridge.
struct BlasterSetupView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let blaster = model.blaster
        NavigationStack {
            List {
                Section {
                    StepRow(number: 1, text: "Insert the batteries and turn on the bridge with its switch.")
                    StepRow(number: 2, text: "Choose OpenPult below within 2 minutes of turning it on.")
                    StepRow(number: 3, text: "When your iPhone asks to pair, tap Pair.")
                } header: {
                    Text("IR Bridge")
                } footer: {
                    Text("The bridge works without Wi‑Fi: your iPhone sends it commands over Bluetooth, and the bridge sends them to the TV by infrared, like a regular remote.")
                }

                availabilitySection(blaster.availability)

                Section {
                    ForEach(blaster.discovered) { found in
                        Button {
                            model.pairBlaster(found)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(found.name).font(.headline)
                                    Text(signalText(found.rssi)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if blaster.pairingCandidate?.id == found.id {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if blaster.isScanning && (blaster.availability == .poweredOn || blaster.availability == .unknown) {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching for the bridge…").foregroundStyle(.secondary)
                        }
                    }
                    if blaster.pairingCandidate != nil {
                        Text("Connecting… If your iPhone asks to pair, tap Pair.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Bridges found")
                }
            }
            .navigationTitle("Without Wi‑Fi")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Wi‑Fi") { model.useNetwork() }
                        .accessibilityLabel("Use Wi‑Fi")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        blaster.startScan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Search Again")
                }
            }
            .task { blaster.startScan() }
            .onDisappear { blaster.stopScan() }
        }
        .overlay(alignment: .bottom) { BannerView(edge: .bottom) }
    }

    @ViewBuilder
    private func availabilitySection(_ availability: BlasterAvailability) -> some View {
        switch availability {
        case .poweredOff:
            Section {
                Label("Turn on Bluetooth in Control Center.", systemImage: "exclamationmark.triangle")
            }
        case .unauthorized:
            Section {
                Text("OpenPult doesn't have access to Bluetooth.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .unsupported:
            Section {
                Label("Bluetooth isn't available on this device.", systemImage: "exclamationmark.triangle")
            }
        case .unknown, .poweredOn:
            EmptyView()
        }
    }

    private func signalText(_ rssi: Int) -> String {
        switch rssi {
        case (-60)...: return String(localized: "Excellent signal", comment: "Bluetooth signal strength of a found bridge.")
        case (-75)...: return String(localized: "Good signal", comment: "Bluetooth signal strength of a found bridge.")
        default: return String(localized: "Weak signal — move your iPhone closer", comment: "Bluetooth signal strength of a found bridge.")
        }
    }
}

/// Bridge details: battery, firmware, aiming mode, forget.
struct BlasterInfoSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @State private var confirmBootloader = false

    var body: some View {
        let blaster = model.blaster
        NavigationStack {
            List {
                Section {
                    LabeledContent("Status", value: connectionText(blaster))
                    LabeledContent("Batteries", value: batteryText(blaster))
                    if let version = blaster.firmwareVersion {
                        LabeledContent("Firmware", value: version)
                    }
                } header: {
                    Text(blaster.saved?.name ?? "OpenPult")
                } footer: {
                    if blaster.status?.isBatteryLow == true {
                        Text("The batteries are running low. Replace all three at once.")
                    }
                }

                if blaster.needsRepair {
                    Section {
                        Button("Reconnect Bridge") {
                            dismiss()
                            model.repairBlaster()
                        }
                    } footer: {
                        Text("First forget OpenPult in Settings → Bluetooth, then turn the bridge off and on.")
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { blaster.isLocating },
                        set: { $0 ? model.startLocate() : blaster.stopLocate() }
                    )) {
                        Label("Aim at TV Sensor", systemImage: "scope")
                    }
                } footer: {
                    Text("The bridge alternates Volume Up and Volume Down. Turn the bridge and its nose until the TV's volume bar blinks steadily. Aiming stops by itself after a minute; the volume may shift by one step.")
                }

                Section {
                    if blaster.hasBootloader {
                        Button("Firmware Update Mode") { confirmBootloader = true }
                    }
                    Button("Forget Bridge", role: .destructive) { confirmForget = true }
                } footer: {
                    if blaster.hasBootloader {
                        Text("In firmware update mode, the bridge shows up on your computer as a USB drive. Copy the .uf2 firmware file to it.")
                    }
                }
            }
            .navigationTitle("Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Forget Bridge?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    dismiss()
                    model.forgetBlaster()
                }
            } message: {
                Text("To connect it again, forget OpenPult in Settings → Bluetooth and turn the bridge off and on.")
            }
            .confirmationDialog("Switch the Bridge to Firmware Update Mode?", isPresented: $confirmBootloader, titleVisibility: .visible) {
                Button("Switch") {
                    Task { await model.enterBlasterBootloader() }
                }
            } message: {
                Text("The remote won't work until you install the firmware or turn the bridge off and on.")
            }
            .onDisappear { blaster.stopLocate() }
        }
        .presentationDetents([.medium, .large])
    }

    private func connectionText(_ blaster: BlasterSession) -> String {
        if blaster.needsRepair { return String(localized: "Needs reconnecting", comment: "Bridge status.") }
        switch blaster.availability {
        case .poweredOff: return String(localized: "Bluetooth is off", comment: "Bridge status.")
        case .unauthorized: return String(localized: "No Bluetooth access", comment: "Bridge status.")
        case .unsupported: return String(localized: "Bluetooth unavailable", comment: "Bridge status.")
        case .unknown, .poweredOn: break
        }
        switch blaster.connection {
        case .ready: return String(localized: "Connected", comment: "Bridge status (the bridge is feminine in Russian).")
        case .connecting: return String(localized: "Connecting…", comment: "Bridge status.")
        case .idle: return String(localized: "Disconnected (connects when you press a button)", comment: "Bridge status in the bridge sheet.")
        }
    }

    private func batteryText(_ blaster: BlasterSession) -> String {
        var parts: [String] = []
        if let percent = blaster.batteryPercent { parts.append(percent.formatted(.percent)) }
        if let millivolts = blaster.status?.batteryMillivolts, millivolts > 0 {
            let volts = Measurement(value: Double(millivolts) / 1000, unit: UnitElectricPotentialDifference.volts)
            parts.append(volts.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2)))))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

private struct StepRow: View {
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
