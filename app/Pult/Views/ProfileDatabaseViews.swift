import SwiftUI
import BraviaKit

/// Download progress / prompt shown where the TV codes are needed but not installed yet.
struct ProfileDatabaseCard: View {
    /// What "Try Again" installs: the pinned version for a first download, the newest after a failed update check.
    var retry: ProfileDatabase.Revision = .pinned
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if let database = model.infrared.profiles {
            content(database)
        } else {
            Text("TV codes are unavailable in this build.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(_ database: ProfileDatabase) -> some View {
        switch database.state {
        case .absent, .installed:
            VStack(alignment: .leading, spacing: 10) {
                Text("The TV codes come from Flipper-IRDB, an open collection of remotes on GitHub. The app downloads them once (about 1.5 MB) and builds the profiles on your iPhone.")
                    .font(.subheadline)
                Text("The codes are downloaded from GitHub only when you ask. GitHub sees your IP address, as with any download.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    database.install(.pinned)
                } label: {
                    Label("Download TV Codes", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        case .downloading(let progress):
            DatabaseProgressRow(progress: progress) { database.cancel() }
        case .building:
            busyRow(Text("Building the TV profiles…"))
        case .removing:
            busyRow(Text("Deleting the TV codes…"))
        case .failed(let error):
            VStack(alignment: .leading, spacing: 10) {
                DatabaseErrorLabel(error: error)
                Button("Try Again") {
                    database.dismissError()
                    database.install(retry)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    private func busyRow(_ text: Text) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            text.foregroundStyle(.secondary)
        }
    }
}

private struct DatabaseErrorLabel: View {
    let error: ProfileDatabaseError

    var body: some View {
        Label {
            Text(verbatim: error.localizedDescription)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.subheadline)
    }
}

/// Download progress with a cancel button.
private struct DatabaseProgressRow: View {
    let progress: ProfileDatabase.Progress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                switch progress.phase {
                case .manifest:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading the list of files…").foregroundStyle(.secondary)
                    }
                case .files:
                    ProgressView(value: progress.fraction)
                    Text(verbatim: "\(progress.completedFiles) / \(progress.totalFiles)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            // Borderless: in a List row a default button would turn the whole row into "Cancel".
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

/// Details of the installed TV codes: version, update, delete.
struct ProfileDatabaseView: View {
    @Environment(RemoteModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        List {
            if let database = model.infrared.profiles {
                content(database)
            } else {
                Text("TV codes are unavailable in this build.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("TV Codes")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if case .failed = model.infrared.profiles?.state { model.infrared.profiles?.dismissError() }
        }
    }

    @ViewBuilder
    private func content(_ database: ProfileDatabase) -> some View {
        if let info = database.info {
            Section {
                LabeledContent("Source") { Text(verbatim: "Flipper-IRDB") }
                LabeledContent("Version") {
                    if let date = info.commitDate {
                        Text(verbatim: "\(info.commit.prefix(7)) · \(date.formatted(date: .abbreviated, time: .omitted))")
                    } else {
                        Text(verbatim: String(info.commit.prefix(7)))
                    }
                }
                LabeledContent("Installed on") { Text(info.installedAt, format: .dateTime.day().month().year()) }
                LabeledContent("Brands") { Text(info.counts.brands, format: .number) }
                LabeledContent("Remotes") { Text(info.counts.profiles, format: .number) }
                LabeledContent("Power codes") { Text(info.counts.powerCodes, format: .number) }
            } footer: {
                Text("A TV remote you already set up keeps working when the codes are updated or deleted.")
            }

            Section {
                switch database.state {
                case .downloading, .building, .removing:
                    ProfileDatabaseCard(retry: .latest)
                case .absent, .installed, .failed:
                    if case .failed(let error) = database.state {
                        DatabaseErrorLabel(error: error)
                    }
                    Button {
                        database.dismissError()
                        database.install(.latest)
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if case .upToDate = database.lastOutcome {
                        Label("The TV codes are up to date.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button {
                        database.dismissError()
                        database.rebuild()
                    } label: {
                        Label("Rebuild Profiles", systemImage: "hammer")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete TV Codes", systemImage: "trash")
                    }
                    .confirmationDialog(Text("Delete the TV codes?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            database.dismissError()
                            database.remove()
                        }
                    } message: {
                        Text("You can download them again at any time.")
                    }
                }
            } footer: {
                Text("Rebuild Profiles builds them again from the downloaded files, without the network.")
            }
        } else {
            Section {
                ProfileDatabaseCard()
            }
        }

        Section {
            Link(destination: URL(string: "https://github.com/Lucaslhm/Flipper-IRDB")!) {
                Label {
                    Text(verbatim: "Flipper-IRDB")
                } icon: {
                    Image(systemName: "safari")
                }
            }
        } header: {
            Text("About the codes")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The codes are downloaded from GitHub only when you ask. GitHub sees your IP address, as with any download.")
                // The note comes from the database's README: show it as plain text, never as Markdown.
                if let note = (try? database.catalog?.source())??.note {
                    Text(verbatim: note)
                }
            }
        }
    }
}
