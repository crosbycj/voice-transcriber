import Foundation
import os

/// Bounds how long a model download may wait on the network without hearing anything back.
///
/// FluidAudio waits up to 30 minutes on a silent request, and its first request, listing the model's
/// files, can't be configured shorter. A network that accepts the connection and then says nothing
/// (a VPN, proxy, firewall or captive portal) would hold the download there, with no error, until then.
///
/// Silence only counts while the operation says it's waiting on the network. Compiling the model is
/// local work that can run a minute without reporting, and isn't a stall.
///
/// A connection can also freeze partway through on a perfectly good network; Hugging Face's servers
/// do it. So a stalled attempt that got further than the one before is started again, and FluidAudio
/// picks up from the bytes already on disk. Only an attempt that gets nowhere is reported.
enum NetworkWatchdog {
    enum Activity: Sendable {
        /// Talking to the server, this far through the whole operation (0 to 1).
        case network(progress: Double)
        /// Working locally: gaps don't count.
        case local
    }

    /// The network went quiet for longer than the limit, and trying again wasn't getting anywhere.
    struct Silence: Error {}

    /// Runs `operation`, cancelling it when it spends longer than `limit` on the network without
    /// reporting activity. The operation must respond to cancellation, which FluidAudio does, so nothing
    /// is left downloading behind the error.
    ///
    /// - Parameter attempts: The most times to run `operation`, if each stalled run made progress.
    static func run<T: Sendable>(
        limit: Duration,
        attempts: Int = 1,
        operation: @escaping @Sendable (_ report: @escaping @Sendable (Activity) -> Void) async throws -> T
    ) async throws -> T {
        var best = 0.0

        for attempt in 1...max(attempts, 1) {
            let monitor = Monitor()

            do {
                return try await runOnce(limit: limit, monitor: monitor, operation: operation)
            } catch is Silence where attempt < attempts && monitor.furthest > best {
                best = monitor.furthest
            }
        }

        throw Silence()
    }

    private static func runOnce<T: Sendable>(
        limit: Duration,
        monitor: Monitor,
        operation: @escaping @Sendable (_ report: @escaping @Sendable (Activity) -> Void) async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation { monitor.record($0) }
            }

            group.addTask {
                while true {
                    try await Task.sleep(for: limit / 4)
                    if monitor.hasBeenSilent(for: limit) {
                        throw Silence()
                    }
                }
            }

            defer { group.cancelAll() }

            // The watchdog only ever throws, so the first result is the operation's.
            while let result = try await group.next() {
                if let result { return result }
            }
            throw CancellationError()
        }
    }

    private final class Monitor: Sendable {
        private struct State {
            var isOnNetwork = false
            var lastHeard = ContinuousClock.now
            var furthest = 0.0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var furthest: Double {
            state.withLock { $0.furthest }
        }

        func record(_ activity: Activity) {
            state.withLock {
                $0.lastHeard = .now

                switch activity {
                case .network(let progress):
                    $0.isOnNetwork = true
                    $0.furthest = max($0.furthest, progress)
                case .local:
                    $0.isOnNetwork = false
                }
            }
        }

        func hasBeenSilent(for limit: Duration) -> Bool {
            state.withLock { $0.isOnNetwork && ContinuousClock.now - $0.lastHeard > limit }
        }
    }
}
