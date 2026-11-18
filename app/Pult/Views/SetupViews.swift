import SwiftUI
import BraviaKit

struct DiscoveryView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var manualHost = ""
    @FocusState private var hostFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.discovered) { tv in
                        Button {
                            model.select(tv)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "tv")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tv.modelName).font(.headline)
                                    Text(tv.host).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if model.isScanning {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching for TVs…").foregroundStyle(.secondary)
                        }
                    } else if model.scanCompleted && model.discovered.isEmpty {
                        Label("No TV found. Check the tips below or enter the IP address manually.", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("TVs on your network")
                }

                if model.localNetworkDenied {
                    Section {
                        Text("iOS hasn't allowed OpenPult to access the local network. Allow it in Settings and search again.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }

                Section {
                    TextField("For example, 192.168.1.50", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($hostFocused)
                        .submitLabel(.go)
                        .onSubmit(connect)
                    Button(action: connect) {
                        HStack {
                            Text("Connect")
                            Spacer()
                            if model.isWorking { ProgressView() }
                        }
                    }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
                } header: {
                    Text("Manual IP address")
                } footer: {
                    Text("You can find the TV's address in its network settings (Network status) or in your router's device list.")
                }

                Section {
                    Button {
                        model.useInfrared()
                    } label: {
                        Label("Use IR Bridge", systemImage: "dot.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Without Wi‑Fi")
                } footer: {
                    Text("If the TV's Wi‑Fi doesn't work, the OpenPult bridge takes commands over Bluetooth and sends them to the TV by infrared.")
                }

                SetupHelpSection()
            }
            .navigationTitle("OpenPult")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.startScan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isScanning)
                    .accessibilityLabel("Search Again")
                }
            }
            .refreshable { await model.startScan() }
            .task {
                if model.discovered.isEmpty && !model.scanCompleted {
                    await model.startScan()
                }
            }
        }
        .overlay(alignment: .bottom) { BannerView(edge: .bottom) }
    }

    private func connect() {
        guard !model.isWorking else { return }
        hostFocused = false
        let host = manualHost
        Task { await model.connectManually(host: host) }
    }
}

struct PairingView: View {
    private enum Method: CaseIterable, Identifiable {
        case pin, psk
        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .pin: "PIN Code"
            case .psk: "Pre-Shared Key"
            }
        }
    }

    @Environment(RemoteModel.self) private var model
    @State private var method: Method = .pin
    @State private var pin = ""
    @State private var psk = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "tv")
                            .font(.largeTitle)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.tv?.modelName ?? String(localized: "TV")).font(.headline)
                            Text(model.tv?.host ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Picker("Method", selection: $method) {
                        ForEach(Method.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    if method == .pin {
                        Text("The TV will show a 4-digit code. Enter it here.")
                    } else {
                        Text("The key is set once in the TV's settings and never expires.")
                    }
                }

                switch method {
                case .pin:
                    pinSection
                case .psk:
                    pskSection
                }

                SetupHelpSection()
            }
            .navigationTitle("Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Other TV") { model.forgetTV() }
                }
            }
            .disabled(model.isWorking)
        }
        .overlay(alignment: .bottom) { BannerView(edge: .bottom) }
    }

    @ViewBuilder
    private var pinSection: some View {
        Section {
            if model.pinRequested {
                TextField("PIN from the TV screen", text: $pin)
                    .keyboardType(.numberPad)
                    .font(.title2.monospacedDigit())
                Button {
                    Task { await model.submitPIN(pin) }
                } label: {
                    progressLabel("Confirm")
                }
                .disabled(pin.count < 4)
                Button("Request PIN Again") {
                    pin = ""
                    Task { await model.requestPIN() }
                }
            } else {
                Button {
                    Task { await model.requestPIN() }
                } label: {
                    progressLabel("Show PIN on TV")
                }
            }
        } footer: {
            Text("If no PIN appears, turn on Remote Device/Renderer in the TV's home network settings, or connect with a Pre-Shared Key.")
        }
    }

    @ViewBuilder
    private var pskSection: some View {
        Section {
            TextField("Pre-Shared Key, for example, 0000", text: $psk)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task { await model.usePSK(psk) }
            } label: {
                progressLabel("Connect")
            }
            .disabled(psk.trimmingCharacters(in: .whitespaces).isEmpty)
        } footer: {
            Text("On the TV: Settings → Network → Home Network Setup → IP Control → Authentication → Normal and Pre-Shared Key, then set the Pre-Shared Key.")
        }
    }

    private func progressLabel(_ title: LocalizedStringResource) -> some View {
        HStack {
            Text(title)
            Spacer()
            if model.isWorking { ProgressView() }
        }
    }
}
