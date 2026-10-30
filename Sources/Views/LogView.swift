import AppKit
import SwiftUI

/// Journal complet, coloré par niveau, filtrable et exportable.
struct LogView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var levels = Set(LogLevel.allCases)
    @State private var follow = true

    var body: some View {
        let lines = model.log.lines.filter { levels.contains($0.level) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) }
        ScrollViewReader { proxy in
            List(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.date, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.secondary)
                    Text(line.text)
                        .foregroundStyle(line.level.color)
                        .fontWeight(line.level == .step ? .semibold : .regular)
                        .textSelection(.enabled)
                }
                .font(.system(.callout, design: .monospaced))
                .listRowSeparator(.hidden)
                .id(line.id)
            }
            .onChange(of: model.log.lines.count) {
                if follow, let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .overlay {
                if lines.isEmpty { ContentUnavailableView("Journal vide", systemImage: "text.alignleft") }
            }
        }
        .searchable(text: $search, prompt: "Filtrer le journal")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(LogLevel.allCases) { level in
                        Toggle(level.rawValue, isOn: Binding(
                            get: { levels.contains(level) },
                            set: { if $0 { levels.insert(level) } else { levels.remove(level) } }))
                    }
                } label: {
                    Label("Niveaux", systemImage: "line.3.horizontal.decrease.circle")
                }
                Toggle(isOn: $follow) { Label("Suivre", systemImage: "arrow.down.to.line") }
                    .help("Défiler automatiquement vers les nouvelles lignes")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.text(of: lines), forType: .string)
                } label: { Label("Copier", systemImage: "doc.on.doc") }
                Button {
                    saveText(model.log.text(of: lines), suggestedName: "PrepareDisk \(Date().formatted(.iso8601.year().month().day())).log")
                } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                Button { model.log.clear() } label: { Label("Vider", systemImage: "trash") }
                    .disabled(model.preparer.isRunning)
            }
        }
    }
}
