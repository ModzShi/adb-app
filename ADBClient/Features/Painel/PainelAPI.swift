import Foundation

/// Snapshot of the web panel state (`GET /_estado`).
///
/// Every field is optional on purpose: the worker evolves and the app must keep
/// rendering (and never crash) when something is missing or renamed.
struct PainelEstado: Decodable {
    struct Ataque: Decodable {
        var ligado: Bool?
        var agenda: Bool?
        var dentro: Bool?
        var forcar: Bool?
        var rps: Int?
        var janelaTxt: String?
    }

    struct Resumo: Decodable {
        var adulteradas: Int?
        var originais: Int?
        var valor_ad: Int?
        var valor_orig: Int?
        var hoje: String?
    }

    struct Guia: Decodable, Identifiable {
        var sub: String?
        var nome: String?
        var online: Bool?
        var min: Int?
        var excluido: Bool?
        var id: String { sub ?? nome ?? "guia" }
    }

    struct Cobranca: Decodable, Identifiable {
        var guia: String?
        var valor: Int?
        var status: String?
        var visto: String?
        var em: String?
        var guiaOn: Bool?
        var id: String { "\(guia ?? "-")|\(visto ?? "-")|\(em ?? "-")|\(valor ?? 0)" }
    }

    struct Diagnostico: Decodable {
        var lidos: Int?
        var erro_kv: String?
    }

    var armado: Bool?
    var auto: Bool?
    var limiar: Int?
    var pendentes_n: Int?
    var pendentes_valor: Int?
    var guias_online: Int?
    var guias_total: Int?
    var syncEm: Double?
    var agora: String?
    var atk: Ataque?
    var resumo: Resumo?
    var listaGuias: [Guia]?
    var ultimas: [Cobranca]?
    var pagas: [Cobranca]?
    var diag: Diagnostico?
    var erro_estado: String?
}

enum PainelError: LocalizedError, Equatable {
    case unauthorized
    case forbidden
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Usuário ou senha do painel estão errados. Toque em 🔑 para corrigir."
        case .forbidden: return "Chave do _ctl inválida (HTTP 403). Confira o campo \"Chave\"."
        case .badResponse(let code): return "O painel respondeu HTTP \(code)."
        }
    }
}

/// Thin client for the panel API. The worker protects `/_estado` and `/_ctl` with
/// HTTP Basic (`nf`/`favela` by default) and returns 401 JSON when it fails.
enum PainelAPI {
    static let base = URL(string: "https://central-nafavela.pages.dev")!

    static func estado(user: String, password: String) async throws -> PainelEstado {
        let request = try makeRequest(path: "/_estado", user: user, password: password,
                                      query: [URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970)))])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        do {
            return try JSONDecoder().decode(PainelEstado.self, from: data)
        } catch {
            throw AdbError.commandFailed("Não entendi a resposta do painel: \(error.localizedDescription)")
        }
    }

    /// Runs a control command, e.g. `["armado": "1"]` or `["sync": "1"]`.
    @discardableResult
    static func control(_ params: [String: String], user: String, password: String,
                        secret: String) async throws -> Bool {
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !secret.isEmpty { items.append(URLQueryItem(name: "k", value: secret)) }
        items.append(URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970))))

        let request = try makeRequest(path: "/_ctl", user: user, password: password, query: items)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("\"erro\":\"chave\"") { throw PainelError.forbidden }
        return text.contains("\"ok\":true") || text.isEmpty
    }

    private static func makeRequest(path: String, user: String, password: String,
                                    query: [URLQueryItem]?) throws -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw PainelError.badResponse(0) }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("ADBClient-iOS", forHTTPHeaderField: "User-Agent")
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw PainelError.badResponse(0) }
        switch http.statusCode {
        case 200...299: return
        case 401: throw PainelError.unauthorized
        case 403: throw PainelError.forbidden
        default: throw PainelError.badResponse(http.statusCode)
        }
    }
}
