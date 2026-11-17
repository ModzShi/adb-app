import SwiftUI

/// Reads Android's wireless-debugging QR code, finds the pairing service over mDNS,
/// pairs with the code found in the QR payload and connects to the device.
struct QRPairSheet: View {
    @EnvironmentObject private var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: MDNSBrowser
    /// Called with the device address so the caller can prefill the manual fields.
    var onPaired: (String, Int?) -> Void

    @State private var payload: ADBQRPayload?
    @State private var manual = ""
    @State private var scannerID = UUID()
    @State private var status: String?
    @State private var error: String?
    @State private var isWorking = false
    @State private var finished = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !finished {
                    QRScannerView { text in handle(text) }
                        .id(scannerID)
                        .frame(height: 300)
                        .clipped()
                }

                Form {
                    if let payload {
                        Section("QR code") {
                            LabeledContent("Service", value: payload.serviceName)
                            LabeledContent("Code", value: payload.password)
                        }
                    }

                    if let status {
                        Section {
                            HStack(spacing: 10) {
                                if isWorking { ProgressView() }
                                Text(status).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if finished {
                        Section {
                            Label("Connected.", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }

                    Section {
                        Button {
                            error = nil
                            payload = nil
                            scannerID = UUID()
                        } label: {
                            Label("Scan again", systemImage: "qrcode.viewfinder")
                        }
                        .disabled(isWorking || finished)
                    } footer: {
                        Text("On the phone: Developer options > Wireless debugging > Pair device with QR code. Keep that screen open while scanning.")
                    }

                    if payload == nil && !finished {
                        Section("Or paste the QR content") {
                            TextField("WIFI:T:ADB;S:…;P:…;;", text: $manual)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button {
                                handle(manual)
                            } label: {
                                Label("Use pasted data", systemImage: "doc.on.clipboard")
                            }
                            .disabled(isWorking || manual.trimmed.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle("Pair with QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isWorking)
                }
            }
            .errorAlert($error)
            .interactiveDismissDisabled(isWorking)
        }
    }

    // MARK: Flow

    private func handle(_ text: String) {
        let text = text.trimmed
        guard !text.isEmpty else { return }
        guard let payload = ADBQRPayload(string: text) else {
            error = "This QR code is not an Android wireless-debugging pairing code."
            if self.payload == nil { scannerID = UUID() }
            return
        }
        self.payload = payload
        manual = ""
        Task { await pair(using: payload) }
    }

    private func pair(using payload: ADBQRPayload) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }

        // Start from a clean discovery list so a stale port is never reused.
        browser.restart()
        status = "Looking for \(payload.serviceName) on the network…"

        guard let pairing = await waitFor(kind: .pairing, name: payload.serviceName, timeout: 20) else {
            status = nil
            error = "Service \(payload.serviceName) not found. Keep the QR screen open and stay on the same Wi-Fi network."
            return
        }

        status = "Pairing with \(pairing.host):\(pairing.port)…"
        let guid: String
        do {
            guid = try await manager.pair(host: pairing.host, port: pairing.port, code: payload.password)
        } catch {
            status = nil
            self.error = error.localizedDescription
            return
        }
        onPaired(pairing.host, nil)
        status = "Paired\(guid.isEmpty ? "" : " (\(guid))"). Waiting for the connection port…"

        // The device advertises the connect service as soon as the QR screen closes.
        browser.restart()
        guard let connect = await waitFor(kind: .connect, host: pairing.host, timeout: 25) else {
            status = "Paired. Open the Wireless debugging screen and tap Connect, then use the port shown there."
            return
        }

        do {
            try await manager.connect(host: connect.host, port: connect.port)
            onPaired(connect.host, connect.port)
            status = "Connected to \(manager.info.displayName) at \(connect.host):\(connect.port)."
            finished = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Polls the discovery list because NetService resolution has no completion we can await.
    private func waitFor(kind: MDNSBrowser.Kind, name: String? = nil, host: String? = nil,
                         timeout: TimeInterval) async -> MDNSBrowser.Service? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
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
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }
}
