import Foundation

public struct BranchChange: Sendable {
    public let checkoutPath: String
    public let newBranch: String
}

@MainActor
public final class GitHeadMonitor {
    public static let shared = GitHeadMonitor()

    public var onBranchChange: ((BranchChange) -> Void)?

    private var monitors: [String: Monitor] = [:]

    private init() {}

    public func startMonitoring(checkoutPath: String) {
        guard monitors[checkoutPath] == nil else { return }

        let headPath = URL(fileURLWithPath: checkoutPath)
            .appendingPathComponent(".git/HEAD")

        guard FileManager.default.fileExists(atPath: headPath.path) else { return }

        let monitor = Monitor(headPath: headPath) { [weak self] in
            Task { @MainActor in
                await self?.handleHeadChange(checkoutPath: checkoutPath)
            }
        }

        if monitor.start() {
            monitors[checkoutPath] = monitor
        }
    }

    public func stopMonitoring(checkoutPath: String) {
        monitors[checkoutPath]?.stop()
        monitors.removeValue(forKey: checkoutPath)
    }

    public func stopAll() {
        for monitor in monitors.values {
            monitor.stop()
        }
        monitors.removeAll()
    }

    private func handleHeadChange(checkoutPath: String) async {
        let repoURL = URL(fileURLWithPath: checkoutPath)
        guard let newBranch = try? await GitService.shared.currentBranch(at: repoURL) else { return }
        onBranchChange?(BranchChange(checkoutPath: checkoutPath, newBranch: newBranch))
    }
}

private final class Monitor: @unchecked Sendable {
    private let headPath: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    init(headPath: URL, onChange: @escaping () -> Void) {
        self.headPath = headPath
        self.onChange = onChange
    }

    func start() -> Bool {
        fileDescriptor = open(headPath.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return false }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        source?.setEventHandler { [weak self] in
            self?.onChange()
        }

        source?.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }

        source?.resume()
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
