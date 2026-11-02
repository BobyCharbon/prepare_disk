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

/// Tout ce qu'il reste à régler sur ce Mac, en rouge, tout en haut de l'app, avec un bouton vers le bon réglage.
/// Chaque ligne disparaît dès que c'est réglé (vérifié au retour dans l'app et toutes les 15 secondes).
struct SetupChecklist: View {
    @Bindable var model: AppModel

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let button: String
        let action: () -> Void
    }

    private var items: [Item] {
        var items: [Item] = []
        if !model.hasFullDiskAccess {
            items.append(Item(id: "fda", icon: "lock.trianglebadge.exclamationmark.fill", title: "Accès complet au disque",
                              detail: "Sans lui, macOS bloque la création des disques bootables. Ajoutez Prepare Disk dans la liste et activez-le.",
                              button: "Ouvrir Accès complet au disque") { model.openFullDiskAccessSettings() })
        }
        if !model.helper.isReady {
            items.append(Item(id: "helper", icon: "key.fill", title: "Configuration unique du mot de passe",
                              detail: model.helper.error ?? "Tapez le mot de passe administrateur une dernière fois : il ne sera plus jamais demandé.",
                              button: model.helper.isInstalling ? "Configuration…" : "Configurer") { Task { await model.helper.install() } })
        }
        if model.agentStatus == .requiresApproval || model.agentStatus == .notRegistered {
            items.append(Item(id: "agent", icon: "menubar.rectangle", title: "Autoriser en arrière-plan",
                              detail: "Nécessaire pour l'icône dans la barre des menus et le téléchargement automatique quand l'app est fermée. Activez Prepare Disk dans « Autoriser en arrière-plan ».",
                              button: "Ouvrir Ouverture et extensions") { Task { await model.registerAgent() }; model.openLoginItemsSettings() })
        }
        if model.notificationsDenied {
            items.append(Item(id: "notif", icon: "bell.slash.fill", title: "Notifications désactivées",
                              detail: "Vous ne serez pas prévenu des téléchargements terminés ni des disques prêts.",
                              button: "Ouvrir Notifications") { model.openNotificationSettings() })
        }
        return items
    }

    var body: some View {
        let items = self.items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(items.count == 1 ? "1 réglage à faire sur ce Mac" : "\(items.count) réglages à faire sur ce Mac",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.red)
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.icon).foregroundStyle(.red).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).fontWeight(.semibold)
                            // Pas de fixedSize : mesuré à largeur nulle, le texte gonflait la fenêtre au-delà de l'écran.
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Button(item.button, action: item.action)
                            .buttonStyle(.borderedProminent).tint(.red)
                            .disabled(item.id == "helper" && model.helper.isInstalling)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.6)))
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

extension Color {
    /// Dernières versions proposées par Apple : rose.
    static let appleLatest = Color(red: 0.96, green: 0.33, blue: 0.62)
    /// Versions validées : couleur du logo de l'entreprise (milieu du dégradé vert → bleu).
    static let validated = Color(red: 0.29, green: 0.52, blue: 0.60)
    static let validatedGreen = Color(red: 0.25, green: 0.57, blue: 0.41)
    static let validatedBlue = Color(red: 0.31, green: 0.45, blue: 0.71)
}

extension ShapeStyle where Self == LinearGradient {
    /// Le dégradé du logo, pour les éléments « versions validées ».
    static var validatedGradient: LinearGradient {
        LinearGradient(colors: [.validatedGreen, .validatedBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Espace libre sur le disque, et ce qu'il faut pour télécharger ce qui manque (en rouge si ça ne suffit pas).
struct DiskSpaceLabel: View {
    @Bindable var model: AppModel

    var body: some View {
        let needed = model.spaceNeeded
        let enough = model.freeSpace >= needed
        HStack(spacing: 4) {
            Image(systemName: enough ? "internaldrive" : "exclamationmark.triangle.fill")
            Text("\(model.freeSpace.fileSize) libres")
            if needed > 0 { Text("· \(needed.fileSize) nécessaires") }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(enough ? Color.secondary : Color.red)
        .help(enough ? "Espace libre sur le disque de ~/prepare_disk." : "Pas assez d'espace pour tout télécharger : libérez de la place.")
    }
}
