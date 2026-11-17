import SwiftUI
import UIKit

/// Shows the pairing QR code that the phone scans
/// (Developer options > Wireless debugging > Pair device with QR code).
///
/// The QR carries a service name and password generated here; the phone starts its
/// pairing server under that name, we find it over mDNS and pair.
struct ShowQRSheet: View {
    @EnvironmentObject private var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: MDNSBrowser
    /// Called with the device address so the caller can prefill the manual fields.
    var onPaired: (String, Int?) -> Void

    @StateObject private var session = PairingSession()
    @State private var credentials = ADBPairingQRCredentials.generate()
    @State private var runToken = UUID()
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        if let image = QRCodeRenderer.image(for: credentials.payload) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240)
                                .padding(10)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.secondary.opacity(0.35)))
                        } else {
                            Text("Could not render the QR code.").foregroundStyle(.secondary)
                        }

                        Text(credentials.payload)
                            .font(.caption2.monospaced())
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button {
                                UIPasteboard.general.string = credentials.payload
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            Spacer()
                            if session.isRunning {
                                Button {
                                    session.cancel()
                                } label: {
                                    Label("Cancel", systemImage: "xmark.circle")
                                }
                            } else {
                                Button {
                                    credentials = ADBPairingQRCredentials.generate()
                                    copied = false
                                    runToken = UUID()
                                } label: {
                                    Label("New code", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                } header: {
                    Text("Pairing QR code")
                } footer: {
                    Text("On the phone: Developer options > Wireless debugging > Pair device with QR code, then point the camera at this QR. Keep the phone on the same Wi-Fi network. If the QR does not work, close this and use \"Pair with code\" below.")
                }

                statusSection
            }
            .navigationTitle("Show pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(session.isRunning)
                }
            }
            .task(id: runToken) {
                await session.run(serviceName: credentials.serviceName, password: credentials.password,
                                  browser: browser, manager: manager)
                guard case .connected = session.phase, let endpoint = session.connectedEndpoint else { return }
                onPaired(endpoint.host, endpoint.port)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            }
            .interactiveDismissDisabled(session.isRunning)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack(spacing: 10) {
                if session.isRunning { ProgressView() }
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.subheadline)
                    if !session.message.isEmpty {
                        Text(session.message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if session.secondsLeft > 0 && session.phase == .searching {
                        Text("\(session.secondsLeft)s").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Status")
        }
    }

    private var statusTitle: String {
        switch session.phase {
        case .idle: return String(localized: "Ready")
        case .searching: return String(localized: "Waiting for the phone…")
        case .pairing: return String(localized: "Pairing…")
        case .waitingForConnection: return String(localized: "Connecting…")
        case .connected: return String(localized: "Connected ✅")
        case .pairedOnly: return String(localized: "Paired (not connected)")
        case .timedOut: return String(localized: "Timed out")
        case .failed: return String(localized: "Error")
        }
    }
}
