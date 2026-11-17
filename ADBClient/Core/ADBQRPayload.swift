import Foundation

/// Payload of Android's "Pair device with QR code" screen, for example:
///
///     WIFI:T:ADB;S:adb-XXXXXX-YYYYYY;P:1234567890123;;
///
/// `S` is the mDNS service instance name and `P` the pairing password; both are
/// exactly the values the manual pairing screen asks for (address, port, code).
struct ADBQRPayload: Equatable {
    let serviceName: String
    let password: String

    init?(string raw: String) {
        let text = raw.trimmed
        guard let prefix = text.range(of: "WIFI:", options: .caseInsensitive),
              prefix.lowerBound == text.startIndex else { return nil }

        var fields: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var escaped = false

        for character in text[prefix.upperBound...] {
            if escaped {
                value.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case ":" where readingKey:
                key = value
                value = ""
                readingKey = false
            case ";":
                if !key.isEmpty { fields[key.uppercased()] = value }
                key = ""
                value = ""
                readingKey = true
            default:
                value.append(character)
            }
        }
        if !key.isEmpty { fields[key.uppercased()] = value }

        if let type = fields["T"]?.trimmed, !type.isEmpty, type.uppercased() != "ADB" { return nil }
        guard let name = fields["S"]?.trimmed, !name.isEmpty,
              let password = fields["P"]?.trimmed, !password.isEmpty else { return nil }

        serviceName = name
        password = password
    }
}
