import SwiftUI

/// Scans a QR code with the camera and pairs with the credentials it carries.
///
/// Useful when the QR is produced by another host (for example Android Studio);
/// for the phone's own "Pair device with QR code" screen use `ShowQRSheet` —
/// that screen is a *scanner*, so it needs a QR to look at.
struct QRPairSheet: View {
    @EnvironmentObject private var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: MDNSBrowser
    /// Called with the device address so the caller can prefill the manual fields.
    var onPaired: (String, Int?) -> Void

    @StateObject private var session = PairingSession()
    @State private var scanned: ADBQRPayload?
    @State private var manual = ""
    @State private var scannerID = UUID()
    @State private var runToken = UUID()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if scanned == nil {
                    QRScannerView { text in handle(text) }
                        .id(scannerID)
                        .frame(height: 280)
                        .clipped()
                }

                Form {
                    if let scanned {
                        Section("QR code") {
                            LabeledContent("Service", value: scanned.serviceName)
                            LabeledContent("Code", value: scanned.password)
                        }
                    }

                    Section {
                        HStack(spacing: 10) {
                            if session.isRunning { ProgressView() }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(statusTitle).font(.subheadline)
                                if !session.message.isEmpty {
                                    Text(session.message).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Status")
                    }

                    Section {
                        Button {
                            error = nil
                            scanned = nil
                            manual = ""
                            session.cancel()
                            scannerID = UUID()
                        } label: {
                            Label("Scan again", systemImage: "qrcode.viewfinder")
                        }
                        .disabled(session.isRunning)
                    } footer: {
                        Text("Point the camera at a `WIFI:T:ADB;S:…;P:…;;` QR code. If the phone shows no QR, close this and use \"Show QR code\".")
                    }

                    if scanned == nil {
                        Section("Or paste the QR content") {
                            TextField("WIFI:T:ADB;S:…;P:…;;", text: $manual)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button {
                                handle(manual)
                            } label: {
                                Label("Use pasted data", systemImage: "doc.on.clipboard")
                            }
                            .disabled(session.isRunning || manual.trimmed.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(session.isRunning)
                }
            }
            .errorAlert($error)
            .task(id: runToken) {
                guard let scanned else { return }
                await session.run(serviceName: scanned.serviceName, password: scanned.password,
                                  browser: browser, manager: manager)
                guard case .connected = session.phase, let endpoint = session.connectedEndpoint else { return }
                onPaired(endpoint.host, endpoint.port)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            }
            .interactiveDismissDisabled(session.isRunning)
        }
    }

    private var statusTitle: String {
        switch session.phase {
        case .idle: return String(localized: "Ready")
        case .searching: return String(localized: "Looking for the device…")
        case .pairing: return String(localized: "Pairing…")
        case .waitingForConnection: return String(localized: "Connecting…")
        case .connected: return String(localized: "Connected ✅")
        case .pairedOnly: return String(localized: "Paired (not connected)")
        case .timedOut: return String(localized: "Timed out")
        case .failed: return String(localized: "Error")
        }
    }

    @MainActor
    private func handle(_ text: String) {
        let value = text.trimmed
        guard !value.isEmpty else { return }
        guard let payload = ADBQRPayload(string: value) else {
            error = "This QR code is not an Android wireless-debugging pairing code."
            if scanned == nil { scannerID = UUID() }
            return
        }
        error = nil
        scanned = payload
        manual = ""
        runToken = UUID()
    }
}
