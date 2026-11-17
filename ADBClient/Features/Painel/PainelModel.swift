import Foundation

/// Holds the panel snapshot and runs its actions.
@MainActor
final class PainelModel: ObservableObject {
    @Published private(set) var estado: PainelEstado?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastLoadedAt: Date?
    @Published private(set) var runningAction: String?
    @Published var autoRefresh = true

    private var lastErrorWasAuth = false

    var needsCredentials: Bool { lastErrorWasAuth }

    // MARK: Loading

    func load(user: String, password: String, secret: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await PainelAPI.estado(user: user, password: password)
            estado = snapshot
            lastLoadedAt = Date()
            error = nil
            lastErrorWasAuth = false
        } catch {
            self.error = error.localizedDescription
            lastErrorWasAuth = (error as? PainelError) == .unauthorized
        }
    }

    func action(_ params: [String: String], label: String,
                user: String, password: String, secret: String) async {
        guard runningAction == nil else { return }
        runningAction = label
        defer { runningAction = nil }
        do {
            _ = try await PainelAPI.control(params, user: user, password: password, secret: secret)
            error = nil
            lastErrorWasAuth = false
        } catch {
            self.error = error.localizedDescription
            lastErrorWasAuth = (error as? PainelError) == .unauthorized
            return
        }
        await load(user: user, password: password, secret: secret)
    }

    // MARK: Derived

    /// Seconds since the platform last synced (`syncEm`, epoch milliseconds).
    var secondsSinceSync: Int? {
        guard let sync = estado?.syncEm, sync > 0 else { return nil }
        return max(0, Int(Date().timeIntervalSince1970 - sync / 1000))
    }

    var syncText: String {
        guard let seconds = secondsSinceSync else { return "nunca sincronizou" }
        if seconds < 90 { return "atualizado agora" }
        let minutes = seconds / 60
        return minutes < 60 ? "atualizado há \(minutes) min" : "atualizado há \(minutes / 60) h"
    }

    var statusLabel: String {
        guard let estado else { return "SEM DADOS" }
        if estado.armado == true { return "ARMADO" }
        if estado.auto == true { return "AUTOMÁTICO" }
        return "DESLIGADO"
    }

    var statusExplain: String {
        guard let estado else { return "" }
        if estado.armado == true { return "tudo já está com o seu pix" }
        if estado.auto == true {
            return "só em UMA cobrança única acima de \(brl(estado.limiar))"
        }
        return "nada sendo desviado agora"
    }

    var outroLink: String {
        guard let estado else { return "" }
        return "há \(estado.pendentes_n ?? 0) outra(s) aberta(s)"
    }

    static func brl(_ cents: Int?) -> String {
        let value = Double(cents ?? 0) / 100
        return "R$ " + String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// `visto` is `YYYY-MM-DD` and `em` is `HH:MM` in the worker payload.
    static func seen(_ cobranca: PainelEstado.Cobranca) -> String {
        let day = (cobranca.visto ?? "").split(separator: "-").reversed().joined(separator: "/")
        let time = cobranca.em ?? ""
        if day.isEmpty && time.isEmpty { return "sem data" }
        return [day, time.isEmpty ? nil : "às \(time)"].compactMap { $0 }.joined(separator: " ")
    }
}
