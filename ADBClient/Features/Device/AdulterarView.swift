import SwiftUI

/// The "ADULTERAR" flow: download the latest APK, push it to the device and
/// reinstall it while keeping the app data (login) with `pm uninstall -k`.
@MainActor
final class AdulterarModel: ObservableObject {
    /// Package replaced by the flow. Edit here if the app id changes.
    static let packageName = "br.com.inovedados.nafavelaturistmo"
    /// APK always published at this address.
    static let apkURL = APKCache.remoteURL
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
    @Published private(set) var cacheStatus: APKCache.Status = .unknown

    private var downloader: FileDownloader?
    private let cache = APKCache()

    var localAPK: URL { cache.file }

    // MARK: Cache

    var cacheTitle: String {
        guard let entry = cache.entry else { return "app.apk ainda não baixado" }
        let when = cache.downloadedAt().map { Self.stamp.string(from: $0) } ?? "?"
        return "app.apk em cache · \(APKCache.size(entry.bytes)) · baixado \(when)"
    }

    var cacheDetail: String? {
        switch cacheStatus {
        case .cached:
            let hash = cache.entry.map { String($0.sha256.prefix(12)) } ?? "?"
            return "versão do site igual ✔ — pulando download (sha256 \(hash)…)"
        case .stale(let remote, _):
            return "o site tem \(APKCache.size(remote)) — download necessário"
        case .checking:
            return "verificando o site…"
        case .empty:
            return "nenhum arquivo local válido"
        case .failed(let message):
            return "site não respondeu: \(message)"
        case .unknown:
            return nil
        }
    }

    func refreshCache() async {
        guard !isRunning else { return }
        cacheStatus = .checking
        cacheStatus = await cache.status()
    }

    /// Forces a fresh download even when the published file looks unchanged.
    func downloadAgain() async {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        failure = nil
        defer {
            isRunning = false
            activity = nil
            fraction = 0
        }
        do {
            try await fetch(force: true)
            result = "app.apk atualizado no cache local."
        } catch {
            failure = error.localizedDescription
        }
    }

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
        if cache.hasUsableFile {
            note("app.apk em cache (\(APKCache.size(cache.localBytes))) ✔ pulando download")
            let status = await cache.status()
            cacheStatus = status
            switch status {
            case .cached:
                note("versão do site igual ✔")
                return
            case .failed:
                note("site não respondeu — usando o arquivo em cache mesmo assim.")
                return
            default:
                note("o site tem uma versão diferente — baixando de novo.")
            }
        }
        try await fetch(force: false)
    }

    private func fetch(force: Bool) async throws {
        if force { cache.remove() }
        cacheStatus = .checking
        note("Baixando app.apk…")

        var announced: Int64?
        if let bytes = try? await APKCache.remoteBytes() {
            announced = bytes
            note("Site anuncia \(APKCache.size(bytes)).")
        }

        let partial = cache.file.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        let downloader = FileDownloader(destination: partial) { [weak self] value in
            self?.fraction = value
            self?.activity = "Baixando \(Int(value * 100))%"
        }
        self.downloader = downloader
        do {
            _ = try await downloader.download(from: APKCache.remoteURL)
        } catch {
            self.downloader = nil
            try? FileManager.default.removeItem(at: partial)
            cacheStatus = .failed(error.localizedDescription)
            throw error
        }
        self.downloader = nil

        try cache.adopt(partial)
        let bytes = cache.localBytes
        note("Baixado \(APKCache.size(bytes)); guardado em Documents/app.apk.")
        if let announced, announced != bytes {
            note("Atenção: recebi \(APKCache.size(bytes)) mas o site anunciava \(APKCache.size(announced)).")
        }
        cacheStatus = .cached
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

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH:mm"
        formatter.locale = Locale(identifier: "pt_BR")
        return formatter
    }()
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
                    Text("Downloads the APK, sends it to the device, removes the old version keeping its data and reinstalls it. The 86 MB file is kept in the app and reused while the published one is unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Cache local") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.cacheTitle).font(.footnote)
                            if let detail = model.cacheDetail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.cacheStatus == .checking { ProgressView() }
                    }
                    HStack {
                        Button {
                            Task { await model.refreshCache() }
                        } label: {
                            Label("Conferir site", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Spacer()
                        Button {
                            Task { await model.downloadAgain() }
                        } label: {
                            Label("Download again", systemImage: "arrow.down.circle")
                        }
                    }
                    .font(.footnote)
                    .disabled(model.isRunning)
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
            .task { await model.refreshCache() }
            .task { await model.run(manager: manager) }
            .interactiveDismissDisabled(model.isRunning)
        }
    }
}
