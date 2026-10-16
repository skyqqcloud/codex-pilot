import Foundation
import Darwin

struct TelemetryFileStamp: Equatable {
    let size: UInt64
    let modified: Date
    let inode: UInt64

    init(_ file: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: file.path)
        size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        modified = values[.modificationDate] as? Date ?? .distantPast
        inode = (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

final class TelemetryFileObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.wmy.pilot.telemetry", qos: .utility)
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?
    private var lastDelivery = Date.distantPast

    init(file: URL, changed: @escaping @Sendable () -> Void) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Watch the directory: the collector atomically replaces samples.json.
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete], queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self, self.pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.pending = nil
                self?.lastDelivery = Date()
                changed()
            }
            self.pending = work
            // Match the previous active refresh budget; busy API streams must
            // not turn every completion into another history scan.
            let delay = max(0.5, 15 - Date().timeIntervalSince(self.lastDelivery))
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        source.resume()
    }

    deinit { pending?.cancel(); source.cancel() }
}
