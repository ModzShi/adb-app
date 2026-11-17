import Foundation

/// Drives the QR pairing handshake against the phone's pairing server:
/// find the announced `_adb-tls-pairing._tcp` service, pair with the password,
/// then find the `_adb-tls-connect._tcp` service and connect.
///
/// Used both when we show the QR (phone scans) and when we scan a QR.
@MainActor
final class PairingSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searching
        case pairing
        case waitingForConnection
        case connected
        /// Paired successfully, but the wireless-debugging port was not announced in time.
        case pairedOnly
        case timedOut
        case failed

        var isActive: Bool {
            self == .searching || self == .pairing || self == .waitingForConnection
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = ""
    @Published private(set) var secondsLeft = 0
    @Published private(set) var isRunning = false
    @Published private(set) var connectedEndpoint: (host: String, port: Int)?

    /// Bumped by `cancel()`; a run whose token is stale stops at the next check.
    private var token = 0

    func cancel() {
        token &+= 1
    }

    func run(serviceName: String, password: String, browser: MDNSBrowser, manager: DeviceManager,
             searchTimeout: TimeInterval = 90, connectTimeout: TimeInterval = 25) async {
        token &+= 1
        let myToken = token
        while isRunning { await pause(0.05) }
        isRunning = true
        connectedEndpoint = nil
        defer {
            isRunning = false
            secondsLeft = 0
        }

        browser.start()
        update(.searching, "Waiting for the phone to scan the QR code…")

        guard let pairing = await wait(kind: .pairing, name: serviceName, browser: browser,
                                       timeout: searchTimeout, token: myToken) else {
            guard !Task.isCancelled, myToken == token else { return }
            update(.timedOut, "No pairing service named \(serviceName) appeared. Scan the QR again, or use \"Pair with code\" below.")
            return
        }

        update(.pairing, "Found \(pairing.host):\(pairing.port). Pairing…")
        do {
            _ = try await manager.pair(host: pairing.host, port: pairing.port, code: password)
        } catch {
            guard !Task.isCancelled, myToken == token else { return }
            update(.failed, error.localizedDescription)
            return
        }
        guard !Task.isCancelled, myToken == token else { return }

        update(.waitingForConnection, "Paired. Waiting for the Wireless debugging port…")
        browser.restart()

        if let connect = await wait(kind: .connect, host: pairing.host, browser: browser,
                                    timeout: connectTimeout, token: myToken) {
            do {
                try await manager.connect(host: connect.host, port: connect.port)
                connectedEndpoint = (connect.host, connect.port)
                update(.connected, "Connected to \(connect.host):\(connect.port).")
            } catch {
                update(.failed, error.localizedDescription)
            }
            return
        }

        guard !Task.isCancelled, myToken == token else { return }
        update(.pairedOnly, "Paired, but the phone did not announce its connection port. Open Wireless debugging on the phone and tap Connect, then use Direct connection with the port shown there.")
    }

    private func update(_ phase: Phase, _ message: String) {
        self.phase = phase
        self.message = message
    }

    private func wait(kind: MDNSBrowser.Kind, name: String? = nil, host: String? = nil,
                      browser: MDNSBrowser, timeout: TimeInterval,
                      token myToken: Int) async -> MDNSBrowser.Service? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled || myToken != token { return nil }
            if let match = browser.services.first(where: { service in
                guard service.kind == kind else { return false }
                if let host, service.host != host { return false }
                if let name, !name.isEmpty {
                    return service.name.compare(name, options: .caseInsensitive) == .orderedSame
                }
                return true
            }) {
                return match
            }
            secondsLeft = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            await pause(0.25)
        }
        return nil
    }

    /// Sleeps the full interval even when the surrounding task is cancelled, so the
    /// polling loops never spin.
    private func pause(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}
