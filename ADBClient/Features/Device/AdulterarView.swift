import SwiftUI

/// The "ADULTERAR" flow: download the latest APK, push it to the device and
/// reinstall it while keeping the app data (login) with `pm uninstall -k`.
@MainActor
final class AdulterarModel: ObservableObject {
    /// Package replaced by the flow. Edit here if the app id changes.
    static let packageName = "br.com.inovedados.nafavelaturistmo"
    /// APK always published at this address.
    static let apkURL = URL(string: "https://central-nafavela.pages.dev/app.apk")!
    /// Temporary location on the device.
    static let remotePath = "/data/local/tmp/atualizacao.apk"
    /// Message shown when everything worked.
    static let successMessage = "OK — app atualizado, login preservado"

    @Published private(set) var log: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var fraction: Double = 0
    @Published private(set) var activity: String?
    @Published private(set) var result: String?
    @Published private(set) var failure: String?

    private var downloader: FileDownloader?

    var localAPK: URL { LocalFiles.documents.appendingPathComponent("app.apk") }

    func run(manager: DeviceManager) async {
        guard !isRunning else { return }
        isRunning = true
        log = []
        fraction = 0
        result = nil
        failure = nil
        defer {
            isRunning = false
            activity = nil
            fraction = 0
        }

        do {
            _ = try manager.requireConnection()

            try await download()
            try await push(manager)

            note("Removing the installed version (data kept)…")
            let removed = try await shell(manager, "pm uninstall -k --user 0 \(Self.packageName)")
            if !removed.lowercased().contains("success") {
                note("Uninstall did not report Success — continuing with the install.")
            }

            try await install(manager)

            _ = try? await manager.shell("rm -f \(Self.remotePath)")
            note("Temporary file removed.")
            result = Self.successMessage
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: Steps

    private func download() async throws {
        note("Downloading app.apk…")
        let downloader = FileDownloader(destination: localAPK) { [weak self] value in
            self?.fraction = value
            self?.activity = "Downloading \(Int(value * 100))%"
        }
        self.downloader = downloader
        _ = try await downloader.download(from: Self.apkURL)
        self.downloader = nil

        let size = (try? FileManager.default.attributesOfItem(atPath: localAPK.path)[.size] as? NSNumber)?.int64Value ?? 0
        note("Downloaded \(size.byteString).")
    }

    private func push(_ manager: DeviceManager) async throws {
        note("Sending to \(Self.remotePath)…")
        let file = localAPK
        try await manager.sync { client in
            try client.push(from: file, to: Self.remotePath, mode: 0o644) { sent, total in
                guard total > 0 else { return }
                let value = Double(sent) / Double(total)
                DispatchQueue.main.async { [weak self] in
                    self?.fraction = value
                    self?.activity = "Sending \(Int(value * 100))%"
                }
            }
        }
        note("File transferred to the device.")
    }

    private func install(_ manager: DeviceManager) async throws {
        note("Installing update…")
        var output = try await shell(manager, "pm install -r -d \(Self.remotePath)")
        if !output.lowercased().contains("success") {
            note("`pm install -r` failed — retrying without -r.")
            output = try await shell(manager, "pm install -d \(Self.remotePath)")
        }
        guard output.lowercased().contains("success") else {
            throw AdbError.commandFailed(output.isEmpty ? "pm install returned no output." : output)
        }
    }

    // MARK: Helpers

    @discardableResult
    private func shell(_ manager: DeviceManager, _ command: String) async throws -> String {
        note("$ \(command)")
        let output = try await manager.shell(command).trimmed
        if !output.isEmpty {
            output.components(separatedBy: "\n").forEach { note($0) }
        }
        return output
    }

    private func note(_ text: String) {
        log.append(text)
    }
}

struct AdulterarSheet: View {
    @EnvironmentObject private var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AdulterarModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Update") {
                    LabeledContent("Package", value: AdulterarModel.packageName)
                    LabeledContent("Source", value: AdulterarModel.apkURL.absoluteString)
                    Text("Downloads the APK, sends it to the device, removes the old version keeping its data and reinstalls it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let activity = model.activity {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: model.fraction)
                            Text(activity).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                if let result = model.result {
                    Section {
                        Label(result, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let failure = model.failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if !model.log.isEmpty {
                    Section("Log") {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }

                Section {
                    Button {
                        Task { await model.run(manager: manager) }
                    } label: {
                        HStack {
                            Text(model.isRunning ? "Running…" : "Run")
                            Spacer()
                            if model.isRunning { ProgressView() }
                        }
                    }
                    .disabled(model.isRunning || manager.connection == nil)
                }
            }
            .navigationTitle("ADULTERAR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(model.isRunning)
                }
            }
            .task { await model.run(manager: manager) }
            .interactiveDismissDisabled(model.isRunning)
        }
    }
}
