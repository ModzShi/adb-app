import Foundation

/// Downloads one URL to a local file, reporting progress in the 0...1 range.
///
/// `URLSession` gives no progress with the async APIs, so this uses the delegate
/// based download task instead. One instance performs one download.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var completion: ((Result<URL, Error>) -> Void)?
    private var copyError: Error?
    private var statusCode: Int?

    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        super.init()
    }

    func download(from url: URL, timeout: TimeInterval = 600) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            completion = { result in continuation.resume(with: result) }
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("ADBClient-iOS", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        let handler = onProgress
        DispatchQueue.main.async { handler(value) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        do {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: destination)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.moveItem(at: location, to: destination)
        } catch {
            copyError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let completion else { return }
        self.completion = nil
        session.finishTasksAndInvalidate()
        if let error { return completion(.failure(error)) }
        if let copyError { return completion(.failure(copyError)) }
        if let statusCode, !(200...299).contains(statusCode) {
            return completion(.failure(AdbError.commandFailed("HTTP \(statusCode)")))
        }
        completion(.success(destination))
    }
}
