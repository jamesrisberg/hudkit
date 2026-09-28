import Foundation

/// Fetches one pinned model file to a temporary location the caller owns.
public enum ModelDownload {
    public enum Failure: LocalizedError {
        case invalidDownload
        public var errorDescription: String? {
            "The model download was incomplete or invalid. Try again."
        }
    }

    /// `https` downloads are size-capped at `expectedSize` and refuse redirects to anything but
    /// `https`; `file` URLs (tests, local mirrors) are copied. Other schemes are refused.
    public static func fetch(
        _ url: URL, expectedSize: Int64, progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        if url.isFileURL {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: copy)
            progress(expectedSize)
            return copy
        }
        guard url.scheme == "https" else { throw Failure.invalidDownload }
        let transfer = ModelTransfer(limit: expectedSize, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(url, continuation: $0) }
        } onCancel: {
            transfer.cancel()
        }
    }
}

/// A session delegate is required: the async download convenience method does not reliably
/// deliver incremental download callbacks to its per-task delegate.
private final class ModelTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var cancelled = false

    init(limit: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.limit = limit
        self.progress = progress
    }

    func start(_ url: URL, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        self.continuation = continuation
        let task = session.downloadTask(with: url)
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        let wasCancelled = cancelled
        continuation = nil
        let activeSession = session
        session = nil
        lock.unlock()
        activeSession?.invalidateAndCancel()
        if wasCancelled, case .success(let temporary) = result {
            try? FileManager.default.removeItem(at: temporary)
            pending?.resume(throwing: CancellationError())
        } else if let pending {
            pending.resume(with: result)
        } else if case .success(let temporary) = result {
            // Cancellation may win while didFinishDownloadingTo moves the file.
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else {
            finish(.failure(ModelDownload.Failure.invalidDownload))
            return
        }
        lock.lock()
        let active = continuation != nil && !cancelled
        lock.unlock()
        if active { progress(totalBytesWritten) }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 200, response.url?.scheme == "https",
              response.expectedContentLength < 0 || response.expectedContentLength == limit,
              let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == limit
        else {
            finish(.failure(ModelDownload.Failure.invalidDownload))
            return
        }
        // URLSession removes its location after this callback returns. Take ownership
        // synchronously, before resuming the task that verifies and installs it.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: owned)
            finish(.success(owned))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
