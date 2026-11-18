import SwiftUI
import UniformTypeIdentifiers
import BraviaKit
import PultIR

/// Which TV the IR bridge controls: a brand profile, an automatic power-code scan, or learning.
struct IRSetupView: View {
    @Environment(RemoteModel.self) private var model
    @State private var query = ""
    @State private var brands: [IRBrand] = []
    @State private var loadFailed = false
    @State private var showsBridge = false

    private var filtered: [IRBrand] {
        query.isEmpty ? brands : brands.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let catalog = model.infrared.catalog
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Button {
                            model.finishIRSetup(.sony(keymap: model.keymap))
                        } label: {
                            BrandRow(name: Text(verbatim: "Sony BRAVIA"), detail: Text("Built-in Sony codes, no test needed"))
                        }
                    } header: {
                        Text(verbatim: "Sony")
                    }

                    Section {
                        NavigationLink {
                            PowerScanView()
                        } label: {
                            Label("Find the Code Automatically", systemImage: "wand.and.stars")
                        }
                        NavigationLink {
                            LearnRemoteView(mode: .newRemote)
                        } label: {
                            Label("Learn Buttons from Your Remote", systemImage: "dot.radiowaves.forward")
                        }
                        .disabled(!model.blaster.canLearn)
                    } header: {
                        Text("Don't know the brand or it isn't listed?")
                    } footer: {
                        if !model.blaster.canLearn {
                            Text("To learn buttons, connect an IR receiver (VS1838B or TSOP38238) to the bridge.")
                        }
                    }
                }

                Section {
                    if catalog == nil {
                        ProfileDatabaseCard()
                    } else {
                        ForEach(filtered) { brand in
                            NavigationLink(value: brand) {
                                BrandRow(name: Text(verbatim: brand.name), detail: Text("\(brand.profiles) remotes in the database"))
                            }
                        }
                        if loadFailed {
                            Text("Couldn't read the TV codes.").foregroundStyle(.secondary)
                            Button("Rebuild Profiles") { model.infrared.profiles?.rebuild() }
                        }
                    }
                } header: {
                    Text("Brands")
                } footer: {
                    if catalog != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Codes from Flipper-IRDB. If no variant works, learn the buttons from your original remote.")
                            NavigationLink("TV Codes") { ProfileDatabaseView() }
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: Text("TV brand"))
            .navigationTitle("Your TV")
            .navigationDestination(for: IRBrand.self) { CodeTestView(brand: $0) }
            .toolbar {
                if model.infrared.remote != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancelIRSetup() }
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Wi‑Fi") { model.useNetwork() }
                            .accessibilityLabel(Text("Use Wi‑Fi"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsBridge = true
                    } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .accessibilityLabel(Text("Bridge"))
                }
            }
            .sheet(isPresented: $showsBridge) {
                BlasterInfoSheet().preferredColorScheme(.dark)
            }
            // Reload when the database is installed, updated or removed.
            .task(id: catalog?.directory) {
                loadFailed = false
                guard let catalog else {
                    brands = []
                    return
                }
                do {
                    brands = try catalog.brands()
                } catch {
                    brands = []
                    loadFailed = true
                }
            }
        }
        .overlay(alignment: .bottom) { BannerView(edge: .bottom) }
    }
}

/// Tries the brand's code variants until the TV reacts.
struct CodeTestView: View {
    let brand: IRBrand
    @Environment(RemoteModel.self) private var model
    @State private var tester: CodeTester?
    @State private var loadFailed = false
    /// Which candidate the last successful send was for; "Did it react?" only applies to that one.
    @State private var sentFor: Attempt?

    private struct Attempt: Equatable {
        let index: Int
        let key: CodeTester.TestKey
        let refining: Bool
    }

    var body: some View {
        List {
            if let tester {
                content(tester)
            } else if loadFailed {
                Text("Couldn't load this brand's codes.").foregroundStyle(.secondary)
                Button("Rebuild Profiles") { model.infrared.profiles?.rebuild() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text(verbatim: brand.name))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard tester == nil else { return }
            guard let catalog = model.infrared.catalog, let profiles = try? catalog.profiles(for: brand) else {
                loadFailed = true
                return
            }
            tester = CodeTester(brand: brand.name, profiles: profiles)
        }
    }

    @ViewBuilder
    private func content(_ tester: CodeTester) -> some View {
        if !tester.canTest {
            Section {
                Text("This brand's remotes have no buttons to test with (power, volume, mute).")
                if let fallback = tester.fallback {
                    Button {
                        model.finishIRSetup(IRRemote(profile: fallback))
                    } label: {
                        Text("Use “\(fallback.name)” Without Testing")
                    }
                }
                NavigationLink("Learn Buttons from Your Remote") { LearnRemoteView(mode: .newRemote) }
            }
        } else {
            if tester.isRefining {
                Section {
                    Text("Several variants match. Let's narrow it down with another button.")
                }
            }
            Section {
                Picker("Button", selection: Binding(get: { tester.testKey }, set: { tester.select($0); sentFor = nil })) {
                    ForEach(tester.availableKeys, id: \.self) { key in
                        Text(title(of: key)).tag(key)
                    }
                }
            } footer: {
                Text("TV off: test with Power. TV on: test with Volume or Mute.")
            }

            if tester.isExhausted {
                Section {
                    Text("No more variants for this button. Pick another button above, find the code automatically, or learn the buttons.")
                    Button("Start Over") {
                        tester.restart()
                        sentFor = nil
                    }
                    NavigationLink("Find the Code Automatically") { PowerScanView() }
                    NavigationLink("Learn Buttons from Your Remote") { LearnRemoteView(mode: .newRemote) }
                }
            } else {
                Section {
                    Button {
                        let attempt = currentAttempt(tester)
                        Task {
                            if await send(tester), attempt == currentAttempt(tester) { sentFor = attempt }
                        }
                    } label: {
                        HStack {
                            Label {
                                Text("Send “\(title(of: tester.testKey))”")
                            } icon: {
                                Image(systemName: "paperplane.fill")
                            }
                            Spacer()
                            if tester.isSending { ProgressView() }
                        }
                    }
                    .disabled(tester.isSending)

                    if sentFor == currentAttempt(tester) {
                        Text("Did the TV react?").font(.headline)
                        Button("Yes, It Works") {
                            if let profile = tester.accept() {
                                model.finishIRSetup(IRRemote(profile: profile))
                            }
                            sentFor = nil
                        }
                        .disabled(tester.isSending)
                        Button("No, Next Variant") {
                            tester.reject()
                            sentFor = nil
                        }
                        .disabled(tester.isSending)
                    }
                } header: {
                    Text("Code \(tester.index + 1) of \(tester.groups.count)")
                }
            }
        }
    }

    private func currentAttempt(_ tester: CodeTester) -> Attempt {
        Attempt(index: tester.index, key: tester.testKey, refining: tester.isRefining)
    }

    private func send(_ tester: CodeTester) async -> Bool {
        do {
            try await tester.test(using: model.infrared) { signal in
                guard await model.sendIR(signal) else { throw CancellationError() }
            }
            return true
        } catch {
            return false
        }
    }

    private func title(of key: CodeTester.TestKey) -> String {
        switch key {
        case .power: return String(localized: "Power")
        case .volumeUp: return String(localized: "Volume Up")
        case .mute: return String(localized: "Mute")
        case .channelUp: return String(localized: "Next Channel")
        case .home: return String(localized: "Home")
        case .up: return String(localized: "Up")
        }
    }
}

/// Sends the most common power codes one after another.
struct PowerScanView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanner: PowerScanner?
    @State private var reacted = false
    @State private var verified = false
    @State private var scanFailed = false

    var body: some View {
        let catalog = model.infrared.catalog
        List {
            Section {
                Text("Turn the TV on and point the bridge at it. The bridge sends the power codes of different brands one by one. As soon as the TV turns off, tap “It Worked”.")
                    .font(.subheadline)
            }
            if catalog == nil {
                Section {
                    ProfileDatabaseCard()
                }
            } else if scanFailed {
                Section {
                    Text("Couldn't read the power codes.").foregroundStyle(.secondary)
                    NavigationLink("Learn Buttons from Your Remote") { LearnRemoteView(mode: .newRemote) }
                }
            } else if let scanner {
                Section {
                    if scanner.isRunning {
                        Button {
                            scanner.markReacted()
                            reacted = true
                            verified = false
                        } label: {
                            Label("It Worked!", systemImage: "hand.raised.fill").font(.headline)
                        }
                        Button("Pause") { scanner.pause() }
                    } else if !reacted {
                        if scanner.isFinished {
                            Button("Start Over") {
                                scanner.restart()
                                start(scanner)
                            }
                            NavigationLink("Learn Buttons from Your Remote") { LearnRemoteView(mode: .newRemote) }
                        } else {
                            Button(scanner.index == 0 ? "Start" : "Continue") { start(scanner) }
                        }
                    }

                    if reacted, let entry = scanner.current {
                        if entry.brands.isEmpty {
                            Text("Turn the TV on and check this code.")
                        } else {
                            Text("This code is used by \(Array(entry.brands.prefix(3)).formatted(.list(type: .and))). Turn the TV on and check the code.")
                        }
                        Button("Check the Code") {
                            Task {
                                do {
                                    try await scanner.sendCurrent(using: model.infrared) { signal in
                                        guard await model.sendIR(signal) else { throw CancellationError() }
                                    }
                                    verified = true
                                } catch {}
                            }
                        }
                        if verified {
                            Button("That's It") { accept(entry) }.font(.headline)
                        }
                        HStack {
                            Button("Previous Code") {
                                scanner.step(by: -1)
                                verified = false
                            }
                            Spacer()
                            Button("Next Code") {
                                scanner.step(by: 1)
                                verified = false
                            }
                        }
                        .buttonStyle(.borderless)
                        if scanner.index + 1 < scanner.entries.count {
                            Button("Keep Searching") {
                                reacted = false
                                scanner.step(by: 1)
                                start(scanner)
                            }
                        }
                    }
                } header: {
                    Text("Code \(min(scanner.index + 1, scanner.entries.count)) of \(scanner.entries.count)")
                } footer: {
                    if scanner.isFinished && !reacted {
                        Text("No more codes. Try learning the buttons from your original remote.")
                    }
                }
            }
        }
        .navigationTitle("Find the Code")
        .navigationBarTitleDisplayMode(.inline)
        // Rebuild the scanner when the database changes, unless the user is in the middle of a scan.
        .task(id: catalog?.directory) {
            guard let catalog else {
                scanner?.pause()
                return
            }
            if let scanner, scanner.isRunning || reacted { return }
            do {
                let entries = try catalog.powerScan()
                scanFailed = entries.isEmpty
                scanner = entries.isEmpty ? nil : PowerScanner(entries: entries)
            } catch {
                scanFailed = true
                scanner = nil
            }
        }
        .onDisappear { scanner?.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { scanner?.pause() }
        }
    }

    private func start(_ scanner: PowerScanner) {
        scanner.start(
            using: model.infrared,
            send: { signal in
                guard await model.sendIR(signal) else { throw CancellationError() }
            },
            onError: { _ in }
        )
    }

    private func accept(_ entry: PowerScanEntry) {
        let profile = try? model.infrared.catalog?.bestProfile(withPower: entry.command, brands: entry.brands)
        if let profile {
            model.finishIRSetup(IRRemote(profile: profile))
        } else {
            model.finishIRSetup(IRRemote(name: "", keys: [RemoteKey.power.rawValue: entry.command]))
        }
    }
}

/// Learn keys from the original remote: a new TV from scratch, or on top of the current remote.
struct LearnRemoteView: View {
    enum Mode {
        /// From the TV choice: starts empty, saved as a new remote.
        case newRemote
        /// From the remote's menu: every learned key is applied right away.
        case editCurrent
    }

    let mode: Mode
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = IRRemote(name: "")
    @State private var learning: LearnableKey?
    @State private var confirmDiscard = false

    private var remote: IRRemote { mode == .editCurrent ? (model.infrared.remote ?? draft) : draft }
    private var hasUnsavedKeys: Bool { mode == .newRemote && !draft.keys.isEmpty }

    var body: some View {
        List {
            Section {
                if model.blaster.canLearn {
                    Text("Point the original remote at the bridge from 5–10 cm and press each button briefly.")
                } else {
                    Text("The bridge has no IR receiver. Connect a VS1838B or TSOP38238 to learn buttons.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            ForEach(LearnableKey.groups) { group in
                Section {
                    ForEach(group.keys) { key in
                        Button {
                            learning = key
                        } label: {
                            HStack {
                                Text(key.title).foregroundStyle(.primary)
                                Spacer()
                                Text(status(of: key)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!model.blaster.canLearn)
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        .navigationTitle("Learn Buttons")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasUnsavedKeys)
        .interactiveDismissDisabled(hasUnsavedKeys)
        .toolbar {
            if hasUnsavedKeys {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { confirmDiscard = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                switch mode {
                case .newRemote:
                    Button("Save") { model.finishIRSetup(draft) }
                        .disabled(draft.keys.isEmpty)
                case .editCurrent:
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog(Text("Discard the learned buttons?"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                draft = IRRemote(name: "")
                dismiss()
            }
        }
        .sheet(item: $learning) { key in
            LearnKeySheet(key: key) { command in
                switch mode {
                case .newRemote:
                    draft.setLearned(command, for: key.id)
                case .editCurrent:
                    model.infrared.setLearned(command, for: key.id)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func status(of key: LearnableKey) -> String {
        if remote.learnedKeys.contains(key.id) { return String(localized: "learned") }
        if remote.keys[key.id] != nil { return String(localized: "from profile") }
        if let remoteKey = RemoteKey(rawValue: key.id), remote.command(for: remoteKey) != nil {
            return String(localized: "via another button")
        }
        return String(localized: "no code")
    }
}

struct LearnableKey: Identifiable, Hashable {
    let id: String
    let title: LocalizedStringResource

    static func == (lhs: LearnableKey, rhs: LearnableKey) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    struct Group: Identifiable {
        let id: String
        let title: LocalizedStringResource
        let keys: [LearnableKey]
    }

    static let groups: [Group] = [
        Group(id: "main", title: "Main", keys: [
            .init(id: "power", title: "Power"),
            .init(id: "volumeUp", title: "Volume Up"),
            .init(id: "volumeDown", title: "Volume Down"),
            .init(id: "mute", title: "Mute"),
            .init(id: "channelUp", title: "Next Channel"),
            .init(id: "channelDown", title: "Previous Channel"),
            .init(id: "input", title: "Input"),
        ]),
        Group(id: "navigation", title: "Navigation", keys: [
            .init(id: "up", title: "Up"),
            .init(id: "down", title: "Down"),
            .init(id: "left", title: "Left"),
            .init(id: "right", title: "Right"),
            .init(id: "confirm", title: "OK"),
            .init(id: "back", title: "Back"),
            .init(id: "home", title: "Home"),
            .init(id: "menu", title: "Menu"),
            .init(id: "options", title: "Action Menu"),
            .init(id: "display", title: "Info"),
        ]),
        Group(id: "numbers", title: "Numbers", keys: (0...9).map { .init(id: "num\($0)", title: "\($0)") }),
        Group(id: "media", title: "Playback and Colors", keys: [
            .init(id: "play", title: "Play"),
            .init(id: "pause", title: "Pause"),
            .init(id: "stop", title: "Stop"),
            .init(id: "previous", title: "Previous"),
            .init(id: "rewind", title: "Rewind"),
            .init(id: "forward", title: "Fast Forward"),
            .init(id: "next", title: "Next"),
            .init(id: "red", title: "Red"),
            .init(id: "green", title: "Green"),
            .init(id: "yellow", title: "Yellow"),
            .init(id: "blue", title: "Blue"),
            .init(id: "subtitles", title: "Subtitles"),
            .init(id: "guide", title: "Guide"),
        ]),
        Group(id: "inputs", title: "Inputs and Power", keys: [
            .init(id: "hdmi1", title: "HDMI \(1)"),
            .init(id: "hdmi2", title: "HDMI \(2)"),
            .init(id: "hdmi3", title: "HDMI \(3)"),
            .init(id: "hdmi4", title: "HDMI \(4)"),
            .init(id: "wakeUp", title: "Turn On"),
            .init(id: "powerOff", title: "Turn Off"),
        ]),
    ]
}

/// Two captures of one button.
struct LearnKeySheet: View {
    let key: LearnableKey
    let onLearned: (IRCommand) -> Void
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var learner: KeyLearner?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "dot.radiowaves.forward")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.pulse, isActive: learner?.isListening == true)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    actions
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Text(key.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .overlay(alignment: .bottom) { BannerView(edge: .bottom) }
        .presentationDetents([.medium, .large])
        .onAppear {
            let learner = KeyLearner(key: key.id)
            self.learner = learner
            model.blaster.activate()
            learner.start(with: model.blaster)
        }
        .onDisappear {
            learner?.cancel(with: model.blaster)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, learner?.state == .interrupted {
                model.blaster.activate()
                learner?.start(with: model.blaster)
            }
        }
        .onChange(of: learner?.state) { _, _ in
            AccessibilityNotification.Announcement(message).post()
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let learner {
            switch learner.state {
            case .learned(let command):
                Text(describe(command)).font(.footnote).foregroundStyle(.secondary)
                Button("Test on the TV") {
                    Task { await model.sendIR(model.infrared.signal(for: command, newPress: true)) }
                }
                Button("Done") {
                    onLearned(command)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            case .failed(let error) where Self.isPermanent(error):
                EmptyView()
            case .interrupted:
                Button("Listen Again") { restart(learner) }
                    .buttonStyle(.borderedProminent)
            case .mismatch, .failed:
                Button("Try Again") { restart(learner) }
                    .buttonStyle(.borderedProminent)
            case .idle, .waitingFirst, .waitingSecond:
                EmptyView()
            }
        }
    }

    private func restart(_ learner: KeyLearner) {
        model.blaster.activate()
        learner.start(with: model.blaster)
    }

    private static func isPermanent(_ error: BlasterError) -> Bool {
        [.noReceiver, .firmwareTooOld, .notSupportedByBoard].contains(error)
    }

    private var message: String {
        let title = String(localized: key.title)
        switch learner?.state ?? .idle {
        case .idle, .waitingFirst:
            return String(localized: "Point the original remote at the bridge and press “\(title)”.")
        case .waitingSecond:
            return String(localized: "Great! Press “\(title)” once more to confirm.")
        case .learned:
            return String(localized: "“\(title)” is learned.")
        case .mismatch:
            return String(localized: "The two presses didn't match. Hold the remote closer and press briefly.")
        case .interrupted:
            return BlasterError.learnInterrupted.localizedDescription
        case .failed(let error):
            return error.localizedDescription
        }
    }

    private func describe(_ command: IRCommand) -> String {
        switch command {
        case .code(let code):
            let address = String(code.address, radix: 16, uppercase: true)
            let value = String(code.command, radix: 16, uppercase: true)
            return String(localized: "Protocol \(code.proto.rawValue), address \(address), command \(value)")
        case .raw(let signal):
            return String(localized: "Protocol not recognized; the recorded signal is saved (\(signal.intro.count + signal.repeat.count) durations)")
        }
    }
}

/// Exports the current remote (profile + learned keys) for sharing or a profile contribution.
struct RemoteExport: Transferable {
    let remote: IRRemote

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { export in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(export.remote)
        }
        .suggestedFileName("remote.openpult.json")
    }
}

private struct BrandRow: View {
    let name: Text
    let detail: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            name.font(.headline).foregroundStyle(.primary)
            detail.font(.caption).foregroundStyle(.secondary)
        }
    }
}
