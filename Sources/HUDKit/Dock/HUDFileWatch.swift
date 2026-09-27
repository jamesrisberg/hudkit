import Foundation

/// Watches one file for content changes by any process: a `DispatchSource` on its directory
/// (so an atomic replace, a delete or a first create are all seen), debounced, and only
/// reporting when the bytes actually changed. Shared by `HUDDockRegistry` and
/// `HUDStatusItemPolicy`.
final class HUDFileWatch: @unchecked Sendable {
    let url: URL
    let queue: DispatchQueue
    let debounce: TimeInterval
    let handler: @Sendable (Data?) -> Void
    private let internalQueue = DispatchQueue(label: "hudkit.file-watch")
    private let source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var last: Data?

    /// Starts watching. `handler` runs on `queue` with the new contents (nil when the file is
    /// gone). Call `cancel()` to stop.
    init(url: URL, queue: DispatchQueue, debounce: TimeInterval, handler: @escaping @Sendable (Data?) -> Void) {
        self.url = url
        self.queue = queue
        self.debounce = debounce
        self.handler = handler
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        last = try? Data(contentsOf: url)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { source = nil; return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .rename, .delete, .link, .extend],
                                                               queue: internalQueue)
        source.setCancelHandler { close(fd) }
        self.source = source
        source.setEventHandler { [weak self] in self?.schedule() }
        source.resume()
    }

    var isWatching: Bool { source != nil }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        pending = item
        internalQueue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func fire() {
        let data = try? Data(contentsOf: url)
        guard data != last else { return }
        last = data
        let handler = self.handler
        queue.async { handler(data) }
    }

    func cancel() {
        internalQueue.sync {
            pending?.cancel()
            pending = nil
        }
        source?.cancel()
    }
}
