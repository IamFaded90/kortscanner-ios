import SwiftUI
import SwiftData
import Charts

struct CardGroup: Identifiable {
    let id: String
    let cards: [CardItem]
    var first: CardItem { cards[0] }
    var total: Double { cards.compactMap(\.priceDKK).reduce(0, +) }
}

struct CollectionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var textSize
    @Query(sort: \CardItem.createdAt, order: .reverse) private var allCards: [CardItem]
    @State private var search = ""
    @State private var sort = "Dato"
    @State private var filter = "Alle"
    @AppStorage("collectionGrid") private var grid = true
    @State private var bySet = false
    @State private var exportURL: URL?
    @State private var error = ""
    @State private var refreshing = false
    @State private var showDelete = false
    @State private var deleting: CardItem?
    private var cards: [CardItem] { allCards.filter { $0.deletedAt == nil } }
    private var visible: [CardItem] {
        cards.filter { card in
            let matches: Bool
            switch filter {
            case "EN": matches = card.language == "EN" || card.language == "English"
            case "JP": matches = card.language == "JP" || card.language == "Japanese"
            case "Slab": matches = !card.gradingCompany.isEmpty
            case "Alle": matches = true
            default: matches = card.status == filter
            }
            return matches && (search.isEmpty || "\(card.name) \(card.number) \(card.setName) \(card.certNumber)".localizedCaseInsensitiveContains(search))
        }
    }
    private var groups: [CardGroup] {
        Dictionary(grouping: visible, by: \.identityKey).map { CardGroup(id: $0.key, cards: $0.value) }.sorted { a, b in
            switch sort {
            case "Pris": return a.total > b.total
            case "Navn": return a.first.name.localizedStandardCompare(b.first.name) == .orderedAscending
            case "Sæt": return a.first.setName.localizedStandardCompare(b.first.setName) == .orderedAscending
            default: return a.first.createdAt > b.first.createdAt
            }
        }
    }
    var body: some View {
        NavigationStack {
            Group {
                if grid {
            ScrollView {
                VStack(spacing: 22) {
                    portfolio
                    controls
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                    if groups.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 70)).foregroundStyle(Theme.accent)
                            Text("Her er plads til dine kort").font(.title2.bold())
                            Text("Scan dit første kort, eller skift filter.").foregroundStyle(.secondary)
                            Button("Scan dit første kort") { AppRouter.shared.requestScan() }.buttonStyle(BigButtonStyle())
                        }.padding(28).frame(maxWidth: .infinity).glassPanel()
                    } else if bySet {
                        ForEach(Array(Set(groups.map { $0.first.setName.isEmpty ? "Ukendt sæt" : $0.first.setName })).sorted(), id: \.self) { set in
                            DisclosureGroup {
                                groupLayout(groups.filter { ($0.first.setName.isEmpty ? "Ukendt sæt" : $0.first.setName) == set })
                            } label: {
                                HStack {
                                    if let logo = groups.first(where: { $0.first.setName == set })?.first.setLogoURL, !logo.isEmpty {
                                        AsyncImage(url: URL(string: logo)) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "folder.fill") }.frame(width: 50, height: 34)
                                    } else { Image(systemName: "folder.fill").foregroundStyle(Theme.blue) }
                                    Text(set).font(.headline)
                                    Spacer()
                                    Text("\(visible.filter { ($0.setName.isEmpty ? "Ukendt sæt" : $0.setName) == set }.count) kort")
                                }.frame(minHeight: 56)
                            }.padding(16).glassPanel()
                        }
                    } else { groupLayout(groups) }
                    if let exportURL { ShareLink("Del eksport", item: exportURL).frame(minHeight: 56) }
                }.padding(20).padding(.bottom, 100)
            }
                } else { listContent }
            }.background(Theme.bg)
                .searchable(text: $search, prompt: "Navn, nummer eller sæt")
                .navigationTitle("Samling")
                .toolbar {
                    Menu {
                        Button("Eksportér CSV") { export(json: false) }
                        Button("Eksportér JSON") { export(json: true) }
                        Button(refreshing ? "Opdaterer priser …" : "Opdatér priser") { Task {
                            refreshing = true
                            await PriceRefreshService.shared.refresh(context, force: true)
                            refreshing = false
                        }}.disabled(refreshing)
                    } label: { Label("Mere", systemImage: "ellipsis.circle").frame(minHeight: 56) }
                }
        }
        .confirmationDialog("Slet dette eksemplar?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Slet eksemplar", role: .destructive) {
                guard let card = deleting else { return }
                let before = BackupCard(card)
                card.deletedAt = Date()
                do {
                    try CollectionMaintenance.commit(context)
                    let after = BackupCard(card)
                    ActionHistory.shared.record("sletning", undo: { before.apply(to: card); CollectionMaintenance.saveAfterUndo(context) }, redo: { after.apply(to: card); CollectionMaintenance.saveAfterUndo(context) })
                } catch { context.rollback(); self.error = "Kortet kunne ikke slettes." }
                deleting = nil
            }
        } message: { Text("Kun dette eksemplar fjernes fra samlingen. Du kan fortryde.") }
    }
    private var listContent: some View {
        List {
            Section { portfolio; controls }.listRowBackground(Color.clear)
            if groups.isEmpty {
                Section {
                    Text("Ingen kort med dette filter.")
                    Button("Scan dit første kort") { AppRouter.shared.requestScan() }.frame(minHeight: 56)
                }
            }
            ForEach(groups) { group in
                DisclosureGroup {
                    ForEach(group.cards) { card in
                        NavigationLink { CardDetailView(card: card) } label: { CardCopyRow(card: card) }
                            .swipeActions {
                                Button(role: .destructive) { deleting = card; showDelete = true } label: { Label("Slet", systemImage: "trash") }
                            }
                    }
                } label: {
                    HStack {
                        thumbnail(group.first, width: 50)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.first.name).font(.headline)
                            Text("x\(group.cards.count) · \(dkk(group.total))")
                        }
                    }.frame(minHeight: 80)
                }
            }
            if let exportURL { ShareLink("Del eksport", item: exportURL).frame(minHeight: 56) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            Color.clear.frame(height: 90).listRowBackground(Color.clear)
        }.scrollContentBackground(.hidden)
    }
    private var portfolio: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DIN SAMLING").font(.caption.bold()).foregroundStyle(.secondary)
            Text(dkk(cards.filter { $0.status != "Solgt" }.compactMap(\.priceDKK).reduce(0, +)))
                .font(.system(.largeTitle, design: .rounded, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1)
            let history = CollectionMaintenance.portfolio
            if let yesterday = history.last(where: { $0.date < Calendar.current.startOfDay(for: Date()) }) {
                let current = cards.filter { $0.status != "Solgt" }.compactMap(\.priceDKK).reduce(0, +)
                let delta = current - yesterday.amount
                Label("\(delta >= 0 ? "+" : "")\(dkk(delta)) siden i går", systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right").foregroundStyle(delta >= 0 ? .green : .red).font(.subheadline)
                Text("Ændringen omfatter også nye kort, solgte kort og sletninger.").font(.caption2).foregroundStyle(.secondary)
            } else { Text("Historikken starter med dine gemte priser.").font(.subheadline).foregroundStyle(.secondary) }
            PriceChart(points: history.map { PricePoint(date: $0.date, amount: $0.amount, source: "Samling") })
            Text("\(cards.count) eksemplarer · \(cards.filter { $0.priceDKK == nil }.count) uden pris").font(.caption)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).glassPanel()
    }
    private var controls: some View {
        HStack {
            Menu {
                ForEach(["Alle", "Beholder", "Til salg", "Solgt", "EN", "JP", "Slab"], id: \.self) { value in Button(value) { filter = value } }
            } label: { Label(filter, systemImage: "line.3.horizontal.decrease").frame(minHeight: 56) }
            Spacer()
            Menu {
                Picker("Sortér", selection: $sort) { ForEach(["Dato", "Pris", "Navn", "Sæt"], id: \.self) { Text($0) } }
                Toggle("Mapper efter sæt", isOn: $bySet)
            } label: { Label("Sortér", systemImage: "arrow.up.arrow.down").frame(minHeight: 56) }
            Spacer()
            Button { grid.toggle() } label: { Label(grid ? "Liste" : "Gitter", systemImage: grid ? "list.bullet" : "square.grid.2x2").frame(minHeight: 56) }
        }.font(.subheadline.bold())
    }
    @ViewBuilder private func groupLayout(_ values: [CardGroup]) -> some View {
        if grid && !textSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(values) { group in groupTile(group) }
            }
        } else {
            LazyVStack(spacing: 14) {
                ForEach(values) { group in
                    DisclosureGroup {
                        ForEach(group.cards) { card in
                            NavigationLink { CardDetailView(card: card) } label: { CardCopyRow(card: card) }
                        }
                    } label: {
                        HStack {
                            thumbnail(group.first, width: 55)
                            VStack(alignment: .leading) {
                                Text(group.first.name).font(.headline)
                                Text("x\(group.cards.count) · \(dkk(group.total))").font(.subheadline)
                            }
                        }.frame(minHeight: 80)
                    }.padding(16).glassPanel()
                }
            }
        }
    }
    private func groupTile(_ group: CardGroup) -> some View {
        NavigationLink {
            if group.cards.count == 1 { CardDetailView(card: group.first) }
            else { CopiesView(group: group) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    thumbnail(group.first, width: nil).aspectRatio(0.716, contentMode: .fit)
                    Text(dkk(group.total)).font(.caption.bold()).padding(8).background(.ultraThinMaterial, in: Capsule()).padding(6)
                }
                Text(group.first.name).font(.headline).lineLimit(2).foregroundStyle(.primary)
                Text("x\(group.cards.count) · \(group.first.number)").font(.caption).foregroundStyle(.secondary)
                if group.first.needsReview { Label("Kontrollér kortet", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            }.padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).stroke(Theme.status(group.first.status).opacity(0.75), lineWidth: 2) }
        }.buttonStyle(.plain)
    }
    private func thumbnail(_ card: CardItem, width: CGFloat?) -> some View {
        Group {
            if let image = UIImage(data: card.front) { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").resizable().scaledToFit().padding(20) }
        }.frame(width: width).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func export(json: Bool) {
        do { exportURL = try CollectionExport.write(cards: cards, json: json) }
        catch { self.error = "Eksporten kunne ikke oprettes." }
    }
}

struct CopiesView: View {
    let group: CardGroup
    @State private var expanded = true
    var body: some View {
        List {
            DisclosureGroup("Eksemplarer · x\(group.cards.filter { $0.deletedAt == nil }.count)", isExpanded: $expanded) {
                ForEach(group.cards.filter { $0.deletedAt == nil }) { card in
                    NavigationLink { CardDetailView(card: card) } label: { CardCopyRow(card: card) }
                }
            }
        }.navigationTitle(group.first.name)
    }
}
struct CardCopyRow: View {
    let card: CardItem
    var body: some View {
        HStack {
            if let image = UIImage(data: card.front) { Image(uiImage: image).resizable().scaledToFit().frame(width: 50, height: 72) }
            VStack(alignment: .leading, spacing: 5) {
                Text("Eksemplar \(card.sequence)").font(.headline)
                Text("\(card.condition) · \(card.status)").foregroundStyle(Theme.status(card.status))
                Text(dkk(card.priceDKK))
            }
        }.frame(minHeight: 80)
    }
}

struct CardDetailView: View {
    @Bindable var card: CardItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var google = GooglePhotosService.shared
    @State private var showBack = false
    @State private var showZoom = false
    @State private var showCondition = false
    @State private var showReview = false
    @State private var showDelete = false
    @State private var showStatus = false
    @State private var saleText = ""
    @State private var showSale = false
    @State private var writing = false
    @State private var error = ""
    @State private var manualPrice = ""
    @State private var productID = ""
    @State private var extraQuotes: [PriceQuote] = []
    @AppStorage("gradingThreshold") private var gradingThreshold = 1000.0
    private var imageData: Data { showBack ? card.back ?? card.front : card.front }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    HoloCardImage(data: imageData).frame(maxHeight: 420).onTapGesture { if card.back != nil { showBack.toggle() } }
                    HStack {
                        Button(showBack ? "Vis forside" : "Vis bagside") { showBack.toggle() }.disabled(card.back == nil)
                        Spacer()
                        Button("Zoom") { showZoom = true }
                    }.frame(minHeight: 56)
                }.padding(18).glassPanel()
                details
                prices
                actions
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.padding(20).padding(.bottom, 100)
        }.background(Theme.bg).navigationTitle(card.name).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showZoom) { ZoomPhotoView(data: imageData) }
            .sheet(isPresented: $showCondition) { ConditionInspector(front: card.front, back: card.back) }
            .sheet(isPresented: $showReview) {
                CardReviewView(images: [card.front, card.back, card.closeup].compactMap { $0 }, initial: CardInfo(name: card.name, number: card.number, language: card.language, setCode: card.setCode, rarity: card.rarity, gradingCompany: card.gradingCompany, grade: card.grade, certNumber: card.certNumber), existing: card) {}
            }
            .sheet(isPresented: $showSale) { saleSheet }
            .confirmationDialog("Skift status", isPresented: $showStatus, titleVisibility: .visible) {
                ForEach(["Beholder", "Til salg", "Solgt"], id: \.self) { value in Button(value) { edit("status") { card.status = value } } }
            }
            .confirmationDialog("Slet dette eksemplar af \(card.name)?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Slet eksemplar", role: .destructive) {
                    edit("sletning") { card.deletedAt = Date() }
                    dismiss()
                }
            } message: { Text("De andre eksemplarer bevares. Du kan fortryde bagefter.") }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kortdata").font(.title2.bold())
            LabeledContent("Eksemplar", value: "#\(card.sequence)")
            LabeledContent("Nummer", value: card.number)
            LabeledContent("Sæt", value: card.setName)
            LabeledContent("Sprog", value: card.language)
            LabeledContent("Sjældenhed", value: card.rarity)
            if !card.gradingCompany.isEmpty {
                LabeledContent("Gradering", value: "\(card.gradingCompany) \(card.grade)")
                LabeledContent("Certifikat", value: card.certNumber)
            }
            Picker("Din vurdering af stand", selection: Binding(get: { card.condition }, set: { value in edit("stand") { card.condition = value } })) {
                ForEach(["NM", "LP", "MP", "HP", "DMG"], id: \.self) { Text($0) }
            }.frame(minHeight: 56)
            Button("Se kanter og hjørner") { showCondition = true }.frame(minHeight: 56)
            Button(card.needsReview ? "Kontrollér genkendelse og find match" : "Ret kortdata og match") { showReview = true }.frame(minHeight: 56)
            if card.keepLocked { Label("Beholder altid · beskyttet PSA-kort", systemImage: "lock.fill").foregroundStyle(.green) }
        }.padding(20).glassPanel()
    }
    private var prices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(dkk(card.priceDKK)).font(.largeTitle.bold())
            Text(card.priceSource).font(.footnote).foregroundStyle(.secondary)
            Text("Prisdato: \(card.priceDate.isEmpty ? "ukendt" : card.priceDate) · kursdato: \(card.exchangeDate.isEmpty ? "ikke relevant" : card.exchangeDate)").font(.caption)
            PriceChart(points: card.priceHistory)
            if card.priceRefreshPending { Label("Prisopdatering venter på net", systemImage: "wifi.slash").font(.caption) }
            if !card.gradingCompany.isEmpty { Text("Dette er en raw-reference. Slab-prisen kan være højere.").font(.footnote) }
            else if (card.priceDKK ?? 0) >= gradingThreshold {
                Text("Gradering værd at undersøge? Kortet er over din DKK-grænse. Sammenlign PSA-gebyr, fragt og graderede salgspriser. Ingen karakter eller gevinst er beregnet.").font(.footnote)
            }
            DisclosureGroup("Ret pris eller hent ekstra priskilde") {
                VStack(spacing: 14) {
                    TextField("Ny pris i DKK", text: $manualPrice).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                    Button("Gem DKK-pris") {
                        guard let amount = Double(manualPrice.replacingOccurrences(of: ",", with: ".")), amount >= 0, amount.isFinite else { error = "Skriv en gyldig pris i DKK."; return }
                        edit("pris") { try card.recordPrice(amount, source: "Manuel vurdering") }
                        manualPrice = ""
                    }.frame(minHeight: 56)
                    TextField("TCGplayer-produkt-id til JustTCG", text: $productID).keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                    Button("Hent JustTCG NM-priser") { Task {
                        do { extraQuotes = try await PriceService.justTCG(productID: productID) }
                        catch { self.error = error.localizedDescription }
                    }}.frame(minHeight: 56)
                    ForEach(Array(extraQuotes.enumerated()), id: \.offset) { _, quote in
                        Button { edit("pris") { try card.recordPrice(quote.dkk, source: quote.source, sourceDate: quote.sourceDate, rateDate: quote.rateDate) } } label: {
                            VStack(alignment: .leading) { Text(dkk(quote.dkk)); Text(quote.source).font(.caption) }.frame(minHeight: 56)
                        }
                    }
                    Text("Kontrollér navn, variant og sprog, før du vælger en pris.").font(.footnote)
                }.padding(.top, 12)
            }.frame(minHeight: 56)
        }.padding(20).glassPanel()
    }
    private var actions: some View {
        VStack(spacing: 16) {
            Button(writing ? "Skriver udkast …" : "Gør klar til salg") { Task {
                writing = true
                do { saleText = try await SalesService.draft(card); showSale = true }
                catch { self.error = error.localizedDescription }
                writing = false
            }}.buttonStyle(BigButtonStyle()).disabled(card.keepLocked || writing)
            Button("Skift status · \(card.status)") { showStatus = true }.buttonStyle(BigButtonStyle(filled: false)).disabled(card.keepLocked)
            DisclosureGroup("Google Fotos og eksemplar") {
                VStack(spacing: 14) {
                    Button("Prøv Google-upload igen") { Task { await UploadQueue.shared.process(force: true) } }.disabled(!google.signedIn).frame(minHeight: 56)
                    if let url = google.albumURL { Link("Åbn album i Google Fotos", destination: url).frame(minHeight: 56) }
                    if !card.uploadError.isEmpty { Text(card.uploadError).font(.footnote) }
                    Button("Slet dette eksemplar", role: .destructive) { showDelete = true }.frame(minHeight: 56)
                }
            }.padding(18).glassPanel()
        }
    }
    private var saleSheet: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $saleText).padding()
                Button("Kopiér udkast") {
                    let old = UIPasteboard.general.string
                    let new = saleText
                    UIPasteboard.general.string = new
                    ActionHistory.shared.record("kopiering", undo: { UIPasteboard.general.string = old }, redo: { UIPasteboard.general.string = new })
                    showSale = false
                }.buttonStyle(BigButtonStyle()).padding()
            }.navigationTitle("Annonceudkast").toolbar { Button("Luk") { showSale = false } }
        }
    }
    private func edit(_ title: String, change: () throws -> Void) {
        let before = BackupCard(card)
        do {
            try change()
            if card.keepLocked { card.status = "Beholder" }
            try CollectionMaintenance.commit(context)
            let after = BackupCard(card)
            ActionHistory.shared.record(title, undo: { before.apply(to: card); CollectionMaintenance.saveAfterUndo(context) }, redo: { after.apply(to: card); CollectionMaintenance.saveAfterUndo(context) })
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        } catch { before.apply(to: card); self.error = "Ændringen kunne ikke gemmes." }
    }
}

enum CollectionExport {
    @MainActor
    static func write(cards: [CardItem], json: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(json ? "Kortscanner-samling.json" : "Kortscanner-samling.csv")
        if json {
            try JSONSerialization.data(withJSONObject: cards.map(\.metadata), options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } else {
            func cell(_ value: String) -> String {
                let dangerous = ["=", "+", "-", "@", "\t", "\r"].contains { value.hasPrefix($0) }
                let safe = dangerous ? "'" + value : value
                return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            let header = ["Navn", "Nummer", "Sæt", "Sprog", "Stand", "Pris DKK", "Status", "Dato", "Firma", "Karakter", "Certifikat", "Priskilde"]
            var rows = [header.map(cell).joined(separator: ";")]
            rows += cards.map { card in
                [card.name, card.number, card.setName, card.language, card.condition,
                 card.priceDKK.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? "",
                 card.keepLocked ? "Beholder" : card.status, ISO8601DateFormatter().string(from: card.createdAt),
                 card.gradingCompany, card.grade, card.certNumber, card.priceSource].map(cell).joined(separator: ";")
            }
            try ("\u{FEFF}" + rows.joined(separator: "\r\n")).write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
