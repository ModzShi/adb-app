import CryptoKit
import Foundation

/// Local copy of the published APK, kept in the app's Documents folder.
///
/// The 86 MB file is downloaded once; later runs only do a cheap `HEAD` and reuse the
/// local copy while the published `Content-Length` stays the same. The sidecar JSON
/// (`app.apk.json`) records what we know about the file so an interrupted or replaced
/// file is detected instead of installed.
///
/// The site sends no `ETag`/`Last-Modified`, so `Content-Length` is the only version
/// signal; "Download again" on the screen forces a refresh regardless.
struct APKCache: Equatable {
    struct Entry: Codable, Equatable {
        var sha256: String
        var bytes: Int64
        /// ISO-8601 timestamp of the download.
        var data: String
    }

    enum Status: Equatable {
        case unknown
        case checking
        /// Local file matches the published one; no download needed.
        case cached
        /// Published file differs from the local one.
        case stale(remoteBytes: Int64, localBytes: Int64)
        /// Nothing usable locally.
        case empty
        case failed(String)
    }

    static let remoteURL = URL(string: "https://central-nafavela.pages.dev/app.apk")!

    var file: URL { LocalFiles.documents.appendingPathComponent("app.apk") }
    var sidecar: URL { LocalFiles.documents.appendingPathComponent("app.apk.json") }

    // MARK: Local state

    var entry: Entry? {
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    var localBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A local file is only trusted when the sidecar agrees with what is on disk.
    var hasUsableFile: Bool {
        entry != nil && localBytes > 0 && entry?.bytes == localBytes
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: sidecar)
    }

    // MARK: Remote

    /// Cheap change probe: only headers, never the body.
    static func remoteBytes(timeout: TimeInterval = 20) async throws -> Int64 {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("ADBClient-iOS", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AdbError.commandFailed("Resposta inválida do site.") }
        guard (200...299).contains(http.statusCode) else { throw AdbError.commandFailed("Site respondeu HTTP \(http.statusCode).") }
        let length = http.expectedContentLength
        guard length > 0 else { throw AdbError.commandFailed("O site não informou o tamanho do arquivo.") }
        return length
    }

    /// Decides whether the cached file can be reused.
    func status() async -> Status {
        do {
            let remote = try await Self.remoteBytes()
            guard hasUsableFile else { return localBytes > 0 ? .stale(remoteBytes: remote, localBytes: localBytes) : .empty }
            return remote == localBytes ? .cached : .stale(remoteBytes: remote, localBytes: localBytes)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Registers a freshly downloaded file, with its real size and hash.
    func adopt(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: url, to: file)
        let entry = Entry(sha256: digest, bytes: Int64(data.count), data: ISO8601DateFormatter().string(from: Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(to: sidecar, options: .atomic)
    }

    // MARK: Display

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func downloadedAt() -> Date? {
        guard let raw = entry?.data else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }
}
