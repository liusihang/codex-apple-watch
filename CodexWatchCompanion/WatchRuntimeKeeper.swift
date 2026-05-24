import Foundation
import WatchKit

protocol WatchRuntimeKeeping: AnyObject {
    func start()
    func stop()
}

final class WatchRuntimeKeeper: NSObject, WatchRuntimeKeeping, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?
    private var restartOnInvalidation = true

    func start() {
        guard session == nil else { return }
        let next = WKExtendedRuntimeSession()
        next.delegate = self
        session = next
        next.start()
    }

    func stop() {
        restartOnInvalidation = false
        session?.invalidate()
        session = nil
    }

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        session = nil
        if restartOnInvalidation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.start()
            }
        }
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        session = nil
        if restartOnInvalidation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.start()
            }
        }
    }
}
