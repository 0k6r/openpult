import SwiftUI
import BraviaKit

struct NumpadSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        NavigationStack {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(1...9, id: \.self) { digit in
                    if let key = RemoteKey.digit(digit) {
                        KeyButton(key: key, text: "\(digit)", label: "\(digit)", size: 68)
                    }
                }
                KeyButton(key: .guide, systemImage: "list.bullet.rectangle", label: "Guide", size: 68)
                KeyButton(key: .num0, text: "0", label: "0", size: 68)
                KeyButton(key: .confirm, text: "OK", label: "OK", size: 68,
                          fill: AnyShapeStyle(Color.accentColor.gradient))
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
            .navigationTitle("Numbers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(470), .large])
    }
}

struct TextInputSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSending = false
    @State private var isVisible = true
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text for the TV", text: $text)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(send)
                } footer: {
                    Text("First open search or any text field on the TV. The text will appear there.")
                }
                Section {
                    Button(action: send) {
                        HStack {
                            Text("Send")
                            Spacer()
                            if isSending { ProgressView() }
                        }
                    }
                    .disabled(text.isEmpty || isSending)
                }
            }
            .navigationTitle("Text Input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { focused = true }
            .onDisappear { isVisible = false }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        let value = text
        Task {
            let delivered = await model.sendText(value)
            isSending = false
            // The user may have closed the sheet while the request was in flight.
            if delivered && isVisible {
                dismiss()
            }
        }
    }
}

struct AppsSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var query = ""

    private var filtered: [TVApp] {
        query.isEmpty ? model.apps : model.apps.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { app in
                Button {
                    Haptics.tap()
                    let model = model
                    dismiss()
                    Task { await model.launch(app) } // errors show on the remote screen
                } label: {
                    HStack(spacing: 14) {
                        AsyncImage(url: app.iconURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Image(systemName: "app.dashed")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(app.title).foregroundStyle(.primary)
                    }
                }
            }
            .overlay {
                if isLoading && model.apps.isEmpty {
                    ProgressView()
                } else if model.apps.isEmpty {
                    ContentUnavailableView(
                        "No Apps",
                        systemImage: "square.grid.2x2",
                        description: Text("The TV didn't return a list of apps.")
                    )
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await model.loadApps()
                isLoading = false
            }
        }
    }
}

struct InputsSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                if isLoading && model.inputs.isEmpty && !model.isInfrared {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading inputs…").foregroundStyle(.secondary)
                    }
                }
                if !model.inputs.isEmpty {
                    Section("TV inputs") {
                        ForEach(model.inputs) { input in
                            Button {
                                Haptics.tap()
                                let model = model
                                dismiss()
                                Task { await model.switchInput(input) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: input.hdmiPort != nil ? "cable.connector" : "tv")
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 26)
                                    Text(input.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    if input.isConnected {
                                        Text("connected", comment: "A device is plugged into this TV input.").font(.caption).foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach(1...4, id: \.self) { port in
                        Button("HDMI \(port)") {
                            press(RemoteKey.hdmi(port: port))
                        }
                    }
                    Button("Open Input Menu on TV") {
                        press(.input)
                    }
                } header: {
                    Text("Quick switch")
                }
            }
            .navigationTitle("Inputs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await model.loadInputs()
                isLoading = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func press(_ key: RemoteKey?) {
        guard let key else { return }
        Haptics.tap()
        let model = model
        dismiss()
        Task { await model.press(key) }
    }
}
