import SwiftUI
import WispCore

struct BrainPropertiesView: View {
    let tab: BrainOpenNote
    var model: BrainModel
    @State private var open = true

    private static let suggestions = ["aliases", "tags", "status", "date"]

    var body: some View {
        let document = BrainDocument(tab.text)
        let properties = document.properties
        if document.hasFrontmatter {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(open ? 90 : 0))
                            Text("Propriedades")
                                .font(Theme.Font.caption)
                        }
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    let missing = Self.suggestions.filter { key in !properties.contains { $0.key == key } }
                    if !missing.isEmpty {
                        Menu {
                            ForEach(missing, id: \.self) { key in
                                Button(key) { model.setProperty(key, to: key == "aliases" || key == "tags" ? .list([]) : .text("")) }
                            }
                        } label: {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Adicionar propriedade")
                    }
                }
                if open {
                    ForEach(properties) { property in
                        BrainPropertyRow(property: property, model: model)
                    }
                }
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceHi.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
        }
    }
}

private struct BrainPropertyRow: View {
    let property: BrainProperty
    var model: BrainModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var shown: String {
        switch property.value {
        case .text(let text): text
        case .list(let items): items.joined(separator: ", ")
        case .complex(let raw): raw
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(property.key)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
            if case .complex(let raw) = property.value {
                Text(raw).font(Theme.Font.tool).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            } else {
                TextField("", text: $draft, prompt: Text("vazio").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, now in if !now { commit() } }
            }
            Spacer(minLength: 0)
            Button { model.removeProperty(property.key) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Remover propriedade")
        }
        .onAppear { draft = shown }
        .onChange(of: shown) { _, value in if !focused { draft = value } }
    }

    private func commit() {
        guard draft != shown else { return }
        switch property.value {
        case .list:
            model.setProperty(property.key, to: .list(draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
        case .text:
            model.setProperty(property.key, to: .text(draft.trimmingCharacters(in: .whitespaces)))
        case .complex:
            break
        }
    }
}

struct BrainSidePanelView: View {
    let tab: BrainOpenNote
    var model: BrainModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 2) {
                ForEach(BrainSidePanel.allCases, id: \.self) { panel in
                    Button(panel.title) { model.sidePanel = panel }
                        .buttonStyle(CompactCapsuleStyle(accent: model.sidePanel == panel))
                }
            }
            .padding(3)
            .background(Theme.surfaceHi, in: Capsule())
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    switch model.sidePanel ?? .backlinks {
                    case .backlinks: backlinks
                    case .outgoing: outgoing
                    case .outline: outline
                    case .tags: tags
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var backlinks: some View {
        if model.backlinks.isEmpty {
            Text("Nenhuma nota aponta para esta.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(Theme.Space.s)
        }
        ForEach(model.backlinks) { link in
            VStack(alignment: .leading, spacing: 2) {
                Button { model.open(link.path, line: link.contexts.first?.line) } label: {
                    Text(link.title).font(Theme.Font.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                .buttonStyle(RowButtonStyle(height: 26))
                ForEach(link.contexts.prefix(3), id: \.line) { context in
                    Button { model.open(link.path, line: context.line) } label: {
                        Text(context.text)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.Space.m)
                }
            }
        }
    }

    @ViewBuilder
    private var outgoing: some View {
        let links = model.outgoing(of: tab)
        if links.isEmpty {
            Text("Esta nota não aponta para outras.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(Theme.Space.s)
        }
        ForEach(Array(links.enumerated()), id: \.offset) { _, link in
            Button {
                model.follow(BrainWikiLink(name: link.name, heading: link.heading), from: tab.path)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: link.target == nil ? "questionmark.circle" : "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(link.target == nil ? Theme.textTertiary : Theme.accent)
                    Text(link.target.map { model.catalog.notes[$0]?.title ?? BrainText.stem(of: $0) } ?? link.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(link.target == nil ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(RowButtonStyle(height: 26))
            .help(link.target == nil ? "Nota que ainda não existe; clique para criar" : (link.target ?? ""))
        }
    }

    @ViewBuilder
    private var outline: some View {
        if tab.render.headings.isEmpty {
            Text("Sem títulos.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(Theme.Space.s)
        }
        ForEach(tab.render.headings) { heading in
            Button {
                model.jump(toLine: heading.line)
            } label: {
                Text(heading.text)
                    .font(heading.level == 1 ? Theme.Font.bodyMedium : Theme.Font.body)
                    .foregroundStyle(heading.level <= 2 ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(heading.level - 1) * 10)
            }
            .buttonStyle(RowButtonStyle(height: 26))
        }
    }

    @ViewBuilder
    private var tags: some View {
        let own = Set(BrainDocument(tab.text).list("tags").map { BrainText.fold($0.hasPrefix("#") ? String($0.dropFirst()) : $0) }).union(tab.render.tags).sorted()
        SectionCaption(text: "Desta nota")
        if own.isEmpty { Text("Sem tags.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(.horizontal, Theme.Space.m) }
        ForEach(own, id: \.self) { tag in tagRow(tag, count: model.tagCounts[tag]) }
        SectionCaption(text: "No brain")
        ForEach(BrainCompletion.tags("", in: model.tagCounts, limit: 25), id: \.self) { tag in tagRow(tag, count: model.tagCounts[tag]) }
    }

    private func tagRow(_ tag: String, count: Int?) -> some View {
        Button {
            model.searchQuery = "#" + tag
            model.showsSearch = true
        } label: {
            HStack {
                Text("#" + tag).font(Theme.Font.body).foregroundStyle(Theme.accentTeal).lineLimit(1)
                Spacer(minLength: 0)
                if let count { Text("\(count)").font(Theme.Font.captionMono).foregroundStyle(Theme.textTertiary) }
            }
        }
        .buttonStyle(RowButtonStyle(height: 26))
    }
}
