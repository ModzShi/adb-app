import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Credentials shown as a QR code for Android's "Pair device with QR code" screen.
///
/// The phone scans the QR, then starts its own pairing server and announces the
/// service `_adb-tls-pairing._tcp` under `serviceName` (AOSP
/// `AdbDebuggingManager.PairingThread`). The phone's parser
/// (`Settings/wifi/dpp/AdbQrCode.java`) requires the exact shape
/// `WIFI:T:ADB;S:<name>;P:<password>;;` with both values non-empty, and un-escapes
/// `\`, `:`, `;` and `,`.
struct ADBPairingQRCredentials: Equatable {
    static let passwordLength = 13

    let serviceName: String
    let password: String

    var payload: String {
        "WIFI:T:ADB;S:\(Self.escaped(serviceName));P:\(Self.escaped(password));;"
    }

    static func generate() -> ADBPairingQRCredentials {
        ADBPairingQRCredentials(serviceName: makeServiceName(), password: makePassword())
    }

    /// `adb-<8 hex>-<6 alphanumeric>`, the same shape Android uses for its own services.
    static func makeServiceName() -> String {
        let hex = String((0..<8).compactMap { _ in "0123456789abcdef".randomElement() })
        let suffix = String((0..<6).compactMap { _ in alphanumerics.randomElement() })
        return "adb-\(hex)-\(suffix)"
    }

    /// The pairing password travels inside the QR code, so it is only read by the phone.
    static func makePassword() -> String {
        String((0..<passwordLength).compactMap { _ in "0123456789".randomElement() })
    }

    private static let alphanumerics = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    private static func escaped(_ value: String) -> String {
        var out = ""
        for character in value {
            if "\\;,:".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

enum QRCodeRenderer {
    /// CoreImage QR bitmap, rendered as a `UIImage` ready for SwiftUI.
    static func image(for text: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
