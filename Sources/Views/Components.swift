import AppKit
import SwiftUI

/// Petite étiquette colorée ("À jour", "Signé"…).
struct Pill: View {
    let text: String
    var color: Color = .secondary
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
    }
}

extension ItemStatus {
    var color: Color {
        switch self {
        case .upToDate: return .green
        case .outdated: return .orange
        case .unknown, .notSelected: return .secondary
        }
    }
    var pill: Pill {
        switch self {
        case .upToDate: return Pill(text: text, color: color, icon: "checkmark")
        case .outdated: return Pill(text: text, color: color, icon: "arrow.up.circle")
        default: return Pill(text: text, color: color)
        }
    }
}

func signedPill(_ signed: Bool?) -> Pill? {
    guard let signed else { return nil }
    return signed ? Pill(text: "Signé", color: .green, icon: "checkmark.seal")
                  : Pill(text: "Plus signé", color: .red, icon: "xmark.seal")
}

/// Carte avec titre, icône et contenu.
struct Card<Content: View, Accessory: View>: View {
    let title: String
    var icon: String?
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(.tint).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, icon: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// Bandeau d'avertissement ou d'information.
struct Banner: View {
    let text: String
    var color: Color = .orange
    var icon = "exclamationmark.triangle.fill"

    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Schéma d'un disque : une barre par partition, proportionnelle à sa taille.
struct PartitionBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let label: String
        let size: Int64
        let color: Color
        var used: Int64? = nil
    }

    let segments: [Segment]
    var total: Int64? = nil

    var body: some View {
        let sum = max(total ?? segments.reduce(0) { $0 + $1.size }, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        let width = max(geo.size.width * CGFloat(Double(segment.size) / Double(sum)), 6)
                        ZStack(alignment: .leading) {
                            segment.color.opacity(0.35)
                            if let used = segment.used, segment.size > 0 {
                                segment.color.frame(width: width * min(CGFloat(Double(used) / Double(segment.size)), 1))
                            }
                        }
                        .frame(width: width)
                        .help("\(segment.label) — \(segment.size.fileSize)")
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 26)
            FlowLegend(segments: segments)
        }
    }
}

private struct FlowLegend: View {
    let segments: [PartitionBar.Segment]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(segments) { s in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 10, height: 10)
                    Text(s.label).lineLimit(1)
                    Text(s.size.fileSize).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

/// Couleurs des partitions macOS, dans l'ordre des emplacements.
let systemColors: [Color] = [.blue, .purple, .teal, .indigo]

/// Ligne "libellé : valeur" alignée.
struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}

/// Enregistre un texte dans un fichier choisi par l'utilisateur.
@MainActor
func saveText(_ text: String, suggestedName: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.allowedContentTypes = [.plainText]
    if panel.runModal() == .OK, let url = panel.url {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Liste des résultats de vérification.
struct ChecksList: View {
    let checks: [CheckResult]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(checks) { check in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(check.ok ? .green : .red)
                    Text(check.label).fontWeight(.medium)
                    Text(check.detail).foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
            }
        }
    }
}

/// Avertit quand l'app n'a pas l'accès complet au disque (nécessaire à createinstallmedia).
struct FullDiskAccessBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        if !model.hasFullDiskAccess {
            VStack(alignment: .leading, spacing: 8) {
                Banner(text: "Prepare Disk n'a pas l'« Accès complet au disque ». Sans lui, macOS bloque la création de l'installateur "
                       + "(« The bless of the installer disk failed »). Ajoutez Prepare Disk dans Réglages Système › Confidentialité "
                       + "et sécurité › Accès complet au disque, puis revenez ici.", color: .red, icon: "lock.trianglebadge.exclamationmark")
                HStack {
                    Button("Ouvrir les Réglages Système") { model.openFullDiskAccessSettings() }
                    Button("Vérifier à nouveau") { model.hasFullDiskAccess = AppModel.checkFullDiskAccess() }
                }
                .controlSize(.small)
            }
        }
    }
}

/// Installateurs et IPSW trouvés hors de leur dossier ou mal nommés : l'utilisateur choisit de les ranger ou de les laisser.
struct SuggestionsCard: View {
    @Bindable var model: AppModel
    let installers: Bool
    @State private var busy = false

    var body: some View {
        let items = model.library.suggestions.filter { $0.isInstaller == installers }
        if !items.isEmpty || model.library.moveError != nil {
            Card(title: items.count == 1 ? "1 fichier à ranger" : "\(items.count) fichiers à ranger", icon: "tray.and.arrow.down",
                 subtitle: "Trouvés ailleurs sur ce Mac ou mal nommés. Ils sont déjà utilisables ; vous pouvez les ranger ou les laisser où ils sont.") {
                if busy { ProgressView().controlSize(.small) }
                else if items.count > 1 { Button("Tout ranger") { organize(items) }.controlSize(.small) }
            } content: {
                if let error = model.library.moveError { Banner(text: error) }
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Text(item.isRename ? "Renommer en « \((item.destination as NSString).lastPathComponent) »"
                                               : "\((item.path as NSString).deletingLastPathComponent.abbreviated) → \(item.destination.abbreviated)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Afficher") { model.library.reveal(item.path) }
                        Button("Laisser ici") { model.library.dismiss(item) }
                        Button(item.isRename ? "Renommer" : "Ranger") { organize([item]) }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                    .disabled(busy)
                }
            }
        }
    }

    private func organize(_ items: [Suggestion]) {
        busy = true
        Task { await model.library.organize(items); busy = false }
    }
}

private extension String {
    var abbreviated: String { (self as NSString).abbreviatingWithTildeInPath }
}

/// Configuration unique : après elle, Prepare Disk ne demande plus jamais le mot de passe administrateur.
struct HelperBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        let helper = model.helper
        if !helper.isReady {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Banner(text: "Configuration unique : avec votre mot de passe une dernière fois, Prepare Disk ne le demandera plus jamais (préparation des disques, rangement des installateurs).",
                           color: .purple, icon: "key.fill")
                    if helper.isInstalling { ProgressView().controlSize(.small) }
                    else { Button("Configurer") { Task { await helper.install() } }.buttonStyle(.borderedProminent) }
                }
                if let error = helper.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}
