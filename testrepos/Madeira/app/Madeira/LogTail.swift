import Foundation

/// Tails a file: opens it, seeks to end, watches for appends via DispatchSource,
/// reads new bytes on a background queue, splits into lines, and passes each
/// line to a callback. Callback runs on the tail's background queue, not main.
final class LogTail {
    private let path: String
    private let onLine: (String) -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.madeira.logtail", qos: .utility)
    private var lineBuffer = Data()
    private var lastSize: off_t = 0

    init(path: String, onLine: @escaping (String) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    func start() {
        queue.async { [weak self] in
            self?.openAndWatch()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
            if let fd = self?.fd, fd >= 0 {
                close(fd)
                self?.fd = -1
            }
        }
    }

    private func openAndWatch() {
        // Open for reading; allow blocking but we'll read incrementally
        fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd < 0 {
            // File may not exist yet — retry after delay
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openAndWatch()
            }
            return
        }

        // Seek to start so we get the whole log (so the UI matches the file)
        lseek(fd, 0, SEEK_SET)
        lastSize = 0

        // Watch for size growth via DispatchSource (kqueue under the hood)
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        s.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 {
                close(fd)
                self?.fd = -1
            }
        }
        s.resume()
        source = s

        // Initial drain
        readAvailable()

        // Also poll every 250ms as a backup — DispatchSource on iOS sometimes
        // misses appends across processes (Wine writes the file, we read it)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        t.resume()
        pollTimer = t
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // One autorelease pool per chunk. With Debug Trace on, Wine writes
            // faster than this loop reads, so the loop (and the GCD work item
            // around it) never ends and the queue's own pool is never drained.
            // Every line's Foundation bridging (String(data:), the contains()
            // filters in LogStore) autoreleases a few small objects; they piled
            // up at ~5 blocks per line until iOS killed the app at ~4.2 GB
            // (Kincaid and a Unity game, ~3 minutes each).
            let reachedEnd: Bool = autoreleasepool {
                let n = buf.withUnsafeMutableBytes { ptr in
                    read(fd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { return true }
                lineBuffer.append(contentsOf: buf[0..<n])
                flushLines()
                return false
            }
            if reachedEnd { break }
        }
    }

    private func flushLines() {
        // Walk the buffer once and drop the consumed prefix once. Removing each
        // line from the front shifted the whole remaining buffer per line, which
        // kept this queue near 100% CPU under Debug Trace volume.
        var start = lineBuffer.startIndex
        while let nlIdx = lineBuffer[start...].firstIndex(of: 0x0A) {
            if nlIdx > start,
               let line = String(data: lineBuffer[start..<nlIdx], encoding: .utf8),
               !line.isEmpty {
                onLine(line)
            }
            start = lineBuffer.index(after: nlIdx)
        }
        if start > lineBuffer.startIndex {
            lineBuffer.removeSubrange(lineBuffer.startIndex..<start)
        }
        // Don't let the buffer grow unbounded if a single "line" is huge
        if lineBuffer.count > 1024 * 1024 {
            lineBuffer.removeAll(keepingCapacity: true)
        }
    }
}
