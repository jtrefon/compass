import Foundation

actor OnlineHarnessExecutionGate {
    static let shared = OnlineHarnessExecutionGate()

    private var isHeld = false
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func release() {
        if let nextContinuation = waitingContinuations.first {
            waitingContinuations.removeFirst()
            nextContinuation.resume()
            return
        }

        isHeld = false
    }
}
