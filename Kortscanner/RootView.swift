import SwiftUI
import SwiftData
import PhotosUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var history = ActionHistory.shared
    @AppStorage("hasSeenOnboarding") private var seen = false
    @AppStorage("appearance") private var appearance = "Mørk"
    var body: some View {
        Group {
            if !seen { OnboardingView { seen = true } }
            else {
                TabView(selection: $router.tab) {
                    Tab("Scan", systemImage: "viewfinder", value: 0) { ScanView() }
                    Tab("Samling", systemImage: "rectangle.stack", value: 1) { CollectionView() }
                    Tab("Indstillinger", systemImage: "gearshape", value: 2) { SettingsView() }
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 12) {
                        if !history.undoTitle.isEmpty {
                            Menu {
                                Button("Fortryd \(history.undoTitle)") { history.undo() }
                                if !history.redoTitle.isEmpty { Button("Gentag \(history.redoTitle)") { history.redo() } }
                            } label: { Label("Fortryd", systemImage: "arrow.uturn.backward").font(.subheadline.bold()).padding(14).frame(minHeight: 56).glassPanel() }
                        } else if !history.redoTitle.isEmpty {
                            Button("Gentag") { history.redo() }.padding(14).frame(minHeight: 56).glassPanel()
                        }
                        Button { router.showChat = true } label: { Label("Spørg", systemImage: "bubble.left.and.text.bubble.right").font(.subheadline.bold()).padding(14).frame(minHeight: 56).glassPanel() }
                    }.padding(.horizontal, 20).padding(.bottom, 83)
                }
            }
        }
        .preferredColorScheme(appearance == "System" ? nil : appearance == "Lys" ? .light : .dark)
        .tint(Theme.blue)
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .sheet(isPresented: $router.showChat) { CollectionChat() }
        .onOpenURL { url in if url.scheme == "kortscanner" { router.tab = url.host == "scan" ? 0 : 1 } }
        .task {
            UploadQueue.shared.bind(context)
            BatchSession.shared.bind(context)
            await GooglePhotosService.shared.restore()
            do { try CollectionMaintenance.commit(context) } catch { DebugLog.shared.error("Samling kunne ikke klargøres") }
            await UploadQueue.shared.process()
            await PriceRefreshService.shared.refresh(context)
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in Task {
            await UploadQueue.shared.process()
            await PriceRefreshService.shared.refresh(context)
        }}
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await PriceRefreshService.shared.refresh(context); await UploadQueue.shared.process() } }
            else {
                do { try BackupManager.shared.write(context) }
                catch { DebugLog.shared.error("Backup ved baggrundsskift fejlede") }
            }
        }
    }
}

struct OnboardingView: View {
    let done: () -> Void
    var body: some View {
        TabView {
            page("Scan forsiden", "Hold kortet stille i rammen. Appen tager selv billedet, når kanterne er tydelige og billedet er skarpt.", "viewfinder")
            page("Vend kortet", "Scan bagsiden. Du kan også tage et nærbillede af kortnummeret eller springe over.", "arrow.triangle.2.circlepath")
            VStack(spacing: 28) {
                page("Gem og del", "Kontrollér kort og pris, og gem i samlingen. Tilslut Google Fotos i Indstillinger, når du er klar.", "rectangle.stack.badge.plus")
                Button("Kom i gang", action: done).buttonStyle(.borderedProminent).controlSize(.large).padding(.bottom, 60)
            }
        }.tabViewStyle(.page)
    }
    private func page(_ title: String, _ text: String, _ icon: String) -> some View {
        VStack(spacing: 28) {
            Image(systemName: icon).font(.system(size: 70)).foregroundStyle(Theme.accent)
            Text(title).font(.largeTitle.bold())
            Text(text).font(.title3).multilineTextAlignment(.center)
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanView: View {
    @State private var batch = false
    @State private var busy = false
    @State private var info = CardInfo()
    @State private var images: [Data] = []
    @State private var review = false
    var body: some View {
        CaptureView(batch: $batch, paused: !batch && (busy || review)) { pages, isBatch in
            if isBatch { BatchSession.shared.capture(pages) }
            else { Task { await process(pages) } }
        }
        .sheet(isPresented: $review) {
            CardReviewView(images: images, initial: info) {}.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }
    private func process(_ pages: [Data]) async {
        guard !pages.isEmpty else { return }
        busy = true
        images = pages
        info = await CardRecognizer.recognize(pages[0])
        if info.language == "Japanese" { info.language = "JP" }
        if info.language == "English" { info.language = "EN" }
        if pages.count > 2 {
            let close = await CardRecognizer.recognize(pages[2])
            if !close.number.isEmpty { info.number = close.number }
        }
        busy = false
        review = true
    }
    static func normalize(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let ratio = min(1, 2400 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.92)
    }
}

struct CardReviewView: View {
    let images: [Data]
    let saved: () -> Void
    let existing: CardItem?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var info: CardInfo
    @State private var matches: [APICard] = []
    @State private var selected: APICard?
    @State private var quotes: [PriceQuote] = []
    @State private var quote: PriceQuote?
    @State private var variant = "normal"
    @State private var setName = ""
    @State private var priceText = ""
    @State private var confirmed = false
    @State private var confidence = "Lav"
    @State private var busy = false
    @State private var message = ""
    init(images: [Data], initial: CardInfo, existing: CardItem? = nil, saved: @escaping () -> Void) {
        self.images = images
        self.saved = saved
        self.existing = existing
        _info = State(initialValue: initial)
        _setName = State(initialValue: existing?.setName ?? "")
        _variant = State(initialValue: existing?.variant ?? "normal")
        _priceText = State(initialValue: existing?.priceDKK.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                if let data = images.first, let image = UIImage(data: data) {
                    Section { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).frame(maxWidth: .infinity) }
                }
                Section("Kortdata · sikkerhed: \(confidence.lowercased())") {
                    TextField("Navn", text: $info.name)
                    TextField("Kortnummer, fx 091/173", text: $info.number)
                    TextField("Sæt", text: $setName)
                    TextField("Sæt-kode", text: $info.setCode)
                    TextField("Sprog, fx EN eller JP", text: $info.language)
                    TextField("Sjældenhed", text: $info.rarity)
                    Button("Find de bedste match") { Task { await lookup() } }.disabled(busy)
                    if busy { ProgressView("Slår kort og pris op …") }
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                if !matches.isEmpty {
                    Section("Tryk på det rigtige kort") {
                        ForEach(matches) { match in
                            Button { Task { await select(match) } } label: {
                                HStack {
                                    AsyncImage(url: URL(string: match.images.small)) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }.frame(width: 65, height: 90)
                                    VStack(alignment: .leading) {
                                        Text(match.name).font(.headline)
                                        Text("\(match.set.name) · \(match.number)").font(.caption)
                                    }
                                    Spacer()
                                    if selected?.id == match.id { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                        }
                    }
                }
                if let selected {
                    Section("Variant og pris") {
                        Picker("Variant", selection: $variant) {
                            ForEach(selected.variants, id: \.self) { Text(variantName($0)).tag($0) }
                        }.onChange(of: variant) { _, _ in Task { await loadQuotes(selected) } }
                        ForEach(Array(quotes.enumerated()), id: \.offset) { _, value in
                            Button { quote = value; priceText = String(format: "%.2f", value.dkk).replacingOccurrences(of: ".", with: ",") } label: {
                                VStack(alignment: .leading) {
                                    Text(dkk(value.dkk)).font(.headline)
                                    Text(value.source).font(.caption)
                                    Text("Prisdato: \(value.sourceDate) · kurs: \(value.rateDate)").font(.caption2)
                                }
                            }
                        }
                    }
                }
                Section("Værdi i danske kroner") {
                    TextField("Pris i DKK (valgfri)", text: $priceText).keyboardType(.decimalPad)
                    Text("Raw-priser er vejledende. Cardmarket-trend er ikke en specifik NM-vurdering. Kontroller variant og stand.").font(.footnote).foregroundStyle(.secondary)
                    if !info.gradingCompany.isEmpty { Text("Et slab kan være mere værd end den viste raw-pris.").font(.footnote) }
                }
                Section("Gradering · valgfrit") {
                    TextField("Firma: PSA, BGS, CGC eller ARS", text: $info.gradingCompany)
                    TextField("Karakter", text: $info.grade)
                    TextField("Certifikatnummer", text: $info.certNumber)
                }
                Section {
                    Toggle("Jeg har kontrolleret kort og variant", isOn: $confirmed)
                    Button("Gem i samling") { save() }
                        .disabled(!confirmed || info.name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }.navigationTitle("Kontrollér dit kort")
                .toolbar { Button("Annuller") { dismiss() } }
                .task { await lookup() }
        }
    }
    private func lookup() async {
        busy = true
        message = ""
        selected = nil
        quotes = []
        quote = nil
        confidence = "Lav"
        confirmed = false
        do {
            let result = try await CardAPI.search(info)
            matches = result.cards
            if let first = matches.first {
                let score = CardAPI.score(first, info: info)
                confidence = score >= 8 && result.total == 1 ? "Høj" : score >= 5 ? "Middel" : "Lav"
                if confidence == "Høj" { await select(first) }
            } else { message = "Intet sikkert match. Ret felterne og søg igen, eller gem manuelt." }
            DebugLog.shared.info("Kortopslag afsluttet: \(matches.count) viste match")
        } catch {
            matches = []
            message = error.localizedDescription
            DebugLog.shared.error("Kortopslag fejlede: \(String(describing: type(of: error)))")
        }
        busy = false
    }
    private func select(_ card: APICard) async {
        selected = card
        info.name = card.name
        setName = card.set.name
        info.setCode = card.set.ptcgoCode ?? card.set.id
        info.rarity = card.rarity ?? info.rarity
        if info.language.isEmpty { info.language = "EN" }
        variant = card.variants.first ?? "normal"
        confirmed = false
        await loadQuotes(card)
    }
    private func loadQuotes(_ card: APICard) async {
        quote = nil
        priceText = ""
        do {
            quotes = try await PriceService.quotes(card, variant: variant)
            if quotes.count == 1, let first = quotes.first {
                quote = first
                priceText = String(format: "%.2f", first.dkk).replacingOccurrences(of: ".", with: ",")
            }
        } catch { message = "Prisen kunne ikke hentes. Du kan skrive en pris i DKK."; quotes = [] }
    }
    private func save() {
        guard let front = images.first else { return }
        let text = priceText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let amount = Double(text)
        guard text.isEmpty || (amount != nil && amount!.isFinite && amount! >= 0) else { message = "Skriv en gyldig pris i DKK."; return }
        let before = existing.map(BackupCard.init)
        let card = existing ?? CardItem(front: front, back: images.count > 1 ? images[1] : nil, info: info)
        card.name = info.name; card.number = info.number; card.language = info.language
        card.setCode = info.setCode; card.rarity = info.rarity
        card.gradingCompany = info.gradingCompany; card.grade = info.grade; card.certNumber = info.certNumber
        card.needsReview = false
        card.closeup = images.count > 2 ? images[2] : nil
        card.setName = setName
        card.apiID = selected?.id ?? existing?.apiID ?? ""
        card.variant = variant
        card.priceDKK = amount
        if let quote, let amount, abs(quote.dkk - amount) < 0.02 {
            card.priceSource = quote.source; card.priceDate = quote.sourceDate; card.exchangeDate = quote.rateDate
        } else if amount != nil { card.priceSource = "Manuel vurdering" }
        if existing == nil {
            card.sequence = UserDefaults.standard.integer(forKey: "lastCardSequence") + 1
            context.insert(card)
        }
        card.priceRefreshPending = amount == nil && !card.apiID.isEmpty
        do {
            if card.keepLocked { card.status = "Beholder" }
            if let amount { try card.recordPrice(amount, source: card.priceSource, sourceDate: card.priceDate, rateDate: card.exchangeDate) }
            try CollectionMaintenance.commit(context)
            UserDefaults.standard.set(max(card.sequence, UserDefaults.standard.integer(forKey: "lastCardSequence")), forKey: "lastCardSequence")
            let after = BackupCard(card)
            if let before {
                ActionHistory.shared.record("kortoplysninger", undo: { before.apply(to: card); CollectionMaintenance.saveAfterUndo(context) }, redo: { after.apply(to: card); CollectionMaintenance.saveAfterUndo(context) })
            } else {
                ActionHistory.shared.record("nyt kort", undo: { card.deletedAt = Date(); CollectionMaintenance.saveAfterUndo(context) }, redo: { card.deletedAt = nil; CollectionMaintenance.saveAfterUndo(context) })
            }
            DebugLog.shared.info("Kort gemt lokalt")
            saved()
            Task { await UploadQueue.shared.process(force: true) }
            dismiss()
        } catch {
            context.rollback()
            message = "Kortet kunne ikke gemmes. Prøv igen."
            DebugLog.shared.error("SwiftData: gemning fejlede")
        }
    }
}
func variantName(_ value: String) -> String {
    ["normal":"Normal", "holofoil":"Holo", "reverseHolofoil":"Reverse holo", "1stEditionHolofoil":"1. udgave · holo", "1stEditionNormal":"1. udgave · normal"][value] ?? value
}
