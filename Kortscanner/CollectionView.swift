import SwiftUI
import SwiftData

struct CollectionView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CardItem.createdAt, order: .reverse) private var allCards: [CardItem]
    @State private var search = ""
    @State private var sort = "Dato"
    @State private var status = "Alle"
    @State private var grouped = true
    @State private var undoID: UUID?
    @State private var exportURL: URL?
    @State private var error = ""
    private var cards: [CardItem] { allCards.filter { $0.deletedAt == nil } }
    private var visible: [CardItem] {
        cards.filter {
            (status == "Alle" || $0.status == status) &&
            (search.isEmpty || "\($0.name) \($0.number) \($0.setName) \($0.certNumber)".localizedCaseInsensitiveContains(search))
        }.sorted {
            switch sort {
            case "Pris": return ($0.priceDKK ?? -1) > ($1.priceDKK ?? -1)
            case "Navn": return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case "Sæt": return $0.setName.localizedStandardCompare($1.setName) == .orderedAscending
            default: return $0.createdAt > $1.createdAt
            }
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dkk(cards.filter { $0.status != "Solgt" }.compactMap(\.priceDKK).reduce(0, +))).font(.largeTitle.bold())
                        Text("\(cards.count) kort · \(cards.filter { $0.priceDKK == nil }.count) uden pris").foregroundStyle(.secondary)
                        Text("Værdien omfatter beholdte kort og kort til salg.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    Picker("Sortér", selection: $sort) { ForEach(["Dato", "Pris", "Navn", "Sæt"], id: \.self) { Text($0) } }
                    Picker("Status", selection: $status) { ForEach(["Alle", "Beholder", "Til salg", "Solgt"], id: \.self) { Text($0) } }
                    Toggle("Mapper efter sæt", isOn: $grouped)
                }
                if let undoID {
                    Button("Fortryd sletning") {
                        if let card = allCards.first(where: { $0.id == undoID }) {
                            card.deletedAt = nil
                            save()
                        }
                        self.undoID = nil
                    }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                if grouped {
                    ForEach(Array(Set(visible.map { $0.setName.isEmpty ? "Ukendt sæt" : $0.setName })).sorted(), id: \.self) { name in
                        Section(name) {
                            ForEach(visible.filter { ($0.setName.isEmpty ? "Ukendt sæt" : $0.setName) == name }) { row($0) }
                        }
                    }
                } else { ForEach(visible) { row($0) } }
                if visible.isEmpty { ContentUnavailableView("Ingen kort endnu", systemImage: "rectangle.stack", description: Text("Scan et kort, eller ændr dit filter.")) }
                if let exportURL { Section { ShareLink("Del eksport", item: exportURL) } }
            }
            .searchable(text: $search, prompt: "Søg efter navn, nummer eller sæt")
            .navigationTitle("Samling")
            .toolbar {
                Menu {
                    Button("Eksportér CSV") { export(json: false) }
                    Button("Eksportér JSON") { export(json: true) }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
    private func row(_ card: CardItem) -> some View {
        NavigationLink { CardDetailView(card: card) } label: {
            HStack(spacing: 14) {
                if let image = UIImage(data: card.front) { Image(uiImage: image).resizable().scaledToFit().frame(width: 58, height: 82).clipShape(RoundedRectangle(cornerRadius: 7)) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(card.name).font(.headline)
                    Text("\(card.number) · \(card.status)").font(.caption).foregroundStyle(.secondary)
                    Text(dkk(card.priceDKK)).font(.subheadline.bold())
                    if card.keepLocked { Label("Beholder altid", systemImage: "lock.fill").font(.caption2) }
                }
            }
        }.swipeActions {
            Button(role: .destructive) { card.deletedAt = Date(); undoID = card.id; save() } label: { Label("Slet", systemImage: "trash") }
        }
    }
    private func save() {
        do { try context.save() }
        catch { context.rollback(); self.error = "Ændringen kunne ikke gemmes." }
    }
    private func export(json: Bool) {
        do { exportURL = try CollectionExport.write(cards: cards, json: json) }
        catch { self.error = "Eksporten kunne ikke oprettes." }
    }
}

struct CardDetailView: View {
    @ObservedObject private var google = GooglePhotosService.shared
    @State private var saleText = ""
    @State private var showSale = false
    @State private var writing = false
    @Bindable var card: CardItem
    @Environment(\.modelContext) private var context
    @State private var error = ""
    @State private var productID = ""
    @State private var extraQuotes: [PriceQuote] = []
    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array([card.front, card.back, card.closeup].compactMap { $0 }.enumerated()), id: \.offset) { _, data in
                            if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(height: 260) }
                        }
                    }
                }
            }
            Section("Kort") {
                LabeledContent("Navn", value: card.name)
                LabeledContent("Nummer", value: card.number)
                LabeledContent("Sæt", value: card.setName)
                LabeledContent("Sprog", value: card.language)
                LabeledContent("Sjældenhed", value: card.rarity)
                if !card.gradingCompany.isEmpty {
                    LabeledContent("Gradering", value: "\(card.gradingCompany) \(card.grade)")
                    LabeledContent("Certifikat", value: card.certNumber)
                }
                Picker("Stand", selection: $card.condition) {
                    ForEach(["NM", "LP", "MP", "HP", "DMG"], id: \.self) { Text($0) }
                }.onChange(of: card.condition) { _, _ in save() }
                Picker("Status", selection: $card.status) {
                    ForEach(["Beholder", "Til salg", "Solgt"], id: \.self) { Text($0) }
                }.disabled(card.keepLocked).onChange(of: card.status) { _, _ in if card.keepLocked { card.status = "Beholder" }; save() }
                if card.keepLocked { Label("Moltres PSA og Snorlax PSA bliver altid i samlingen.", systemImage: "lock.fill").font(.footnote) }
            }
            Section("Værdi") {
                Text(dkk(card.priceDKK)).font(.title.bold())
                Text(card.priceSource).font(.footnote)
                if !card.priceDate.isEmpty { Text("Prisdato: \(card.priceDate) · valutakurs: \(card.exchangeDate)").font(.caption) }
                if !card.gradingCompany.isEmpty { Text("Raw-prisen er kun en reference. Slab-prisen kan være højere.").font(.footnote) }
                TextField("TCGplayer-produkt-id til JustTCG", text: $productID).keyboardType(.numberPad)
                Button("Hent ekstra NM-priser fra JustTCG") { Task {
                    do { extraQuotes = try await PriceService.justTCG(productID: productID) }
                    catch { self.error = error.localizedDescription }
                }}
                ForEach(Array(extraQuotes.enumerated()), id: \.offset) { _, value in
                    Button {
                        card.priceDKK = value.dkk; card.priceSource = value.source
                        card.priceDate = value.sourceDate; card.exchangeDate = value.rateDate; save()
                    } label: { VStack(alignment: .leading) { Text(dkk(value.dkk)); Text(value.source).font(.caption) } }
                }
                Text("Vælg kun en ekstra pris, når navn, udgave og sprog svarer til dit kort.").font(.caption)
            }
            Section("Deling") {
                Button(writing ? "Skriver udkast …" : "Gør klar til salg") { Task {
                    writing = true
                    do { saleText = try await SalesService.draft(card); showSale = true }
                    catch { self.error = error.localizedDescription }
                    writing = false
                }}.disabled(card.keepLocked || writing)
                Button("Prøv Google-upload igen") { Task { await UploadQueue.shared.process(force: true) } }.disabled(!google.signedIn)
                if let url = google.albumURL { Link("Åbn album i Google Fotos", destination: url) }
                if !card.uploadError.isEmpty { Text(card.uploadError).font(.footnote) }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showSale) {
            NavigationStack {
                VStack {
                    TextEditor(text: $saleText).padding()
                    Button("Kopiér udkast") { UIPasteboard.general.string = saleText; showSale = false }.buttonStyle(.borderedProminent).padding()
                    Text("Du bestemmer selv, hvor du bruger udkastet.").font(.footnote)
                }.navigationTitle("Annonceudkast").toolbar { Button("Luk") { showSale = false } }
            }
        }
        .navigationTitle(card.name).navigationBarTitleDisplayMode(.inline)
    }
    private func save() {
        do { try context.save() }
        catch { context.rollback(); self.error = "Ændringen kunne ikke gemmes." }
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
