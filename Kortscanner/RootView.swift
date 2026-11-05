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
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("KortscannerScanRequested"))) { _ in router.requestScan() }
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
        images[0] = await CardRecognizer.upright(pages[0])
        info = await CardRecognizer.recognize(images[0])
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
    @State private var editing = false
    @State private var cancel = false
    @Environment(\.dynamicTypeSize) private var textSize
    private var parsedPrice: Double? { Double(priceText.replacingOccurrences(of: ",", with: ".")) }
    private var confidenceColor: Color { confidence == "Høj" ? .green : confidence == "Middel" ? .yellow : .red }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let data = images.first, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(info.name.isEmpty ? "Navn mangler · tryk Ret" : info.name).font(.title.bold())
                        Text("\(info.number) · \(setName.isEmpty ? "Sæt mangler" : setName) · \(info.language.isEmpty ? "Sprog ukendt" : info.language)").foregroundStyle(.secondary)
                        Text("Variant: \(variantName(variant))").font(.subheadline)
                        Text(dkk(parsedPrice)).font(.largeTitle.bold())
                        Label("Sikkerhed: \(confidence.lowercased())", systemImage: "circle.fill").foregroundStyle(confidenceColor).font(.subheadline.bold())
                        if busy { ProgressView("Finder match og pris …") }
                        if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).glassPanel()
                    if !matches.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Vælg det rigtige kort").font(.headline)
                            LazyVGrid(columns: textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                ForEach(matches) { match in
                                    Button { Task { await select(match) } } label: {
                                        VStack(spacing: 7) {
                                            AsyncImage(url: URL(string: match.images.small)) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }.frame(height: 130)
                                            Text(match.name).font(.caption.bold()).lineLimit(3)
                                            Text("\(match.set.name) · \(match.number)").font(.caption2).lineLimit(3)
                                            if selected?.id == match.id { Label("Valgt", systemImage: "checkmark.circle.fill").font(.caption) }
                                        }.padding(8).frame(maxWidth: .infinity).background(selected?.id == match.id ? Theme.blue.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.padding(16).glassPanel()
                    }
                    if editing { editingFields }
                    Toggle("Jeg har kontrolleret kort og variant", isOn: $confirmed).font(.subheadline).padding(16).frame(minHeight: 56).glassPanel()
                    HStack(spacing: 14) {
                        Button("Gem") { save() }.buttonStyle(BigButtonStyle()).disabled(!confirmed || info.name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        Button(editing ? "Skjul rettelser" : "Ret") { editing.toggle() }.buttonStyle(BigButtonStyle(filled: false))
                    }
                    Text("Priser er vejledende. En slab-pris kan være højere end raw-prisen.").font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Theme.bg).navigationTitle("Dit kort").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { cancel = true } }
                .interactiveDismissDisabled()
                .confirmationDialog("Forlad kortet uden at gemme?", isPresented: $cancel, titleVisibility: .visible) {
                    Button("Forlad uden at gemme", role: .destructive) { dismiss() }
                }
                .task { await lookup() }
        }
    }
    private var editingFields: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Kortdata").font(.headline)
                TextField("Navn", text: $info.name).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                TextField("Kortnummer", text: $info.number).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                TextField("Sæt", text: $setName).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                DisclosureGroup("Sprog, sæt-kode og sjældenhed") {
                    TextField("Sprog, fx EN eller JP", text: $info.language).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                    TextField("Sæt-kode", text: $info.setCode).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                    TextField("Sjældenhed", text: $info.rarity).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                }.frame(minHeight: 56)
                Button("Find match igen") { Task { await lookup() } }.frame(minHeight: 56).disabled(busy)
            }.padding(18).glassPanel()
            VStack(alignment: .leading, spacing: 14) {
                Text("Variant og pris").font(.headline)
                if let selected {
                    Picker("Variant", selection: $variant) { ForEach(selected.variants, id: \.self) { Text(variantName($0)).tag($0) } }
                        .frame(minHeight: 56).onChange(of: variant) { _, _ in Task { await loadQuotes(selected) } }
                    ForEach(Array(quotes.enumerated()), id: \.offset) { _, value in
                        Button { quote = value; priceText = String(format: "%.2f", value.dkk).replacingOccurrences(of: ".", with: ",") } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(dkk(value.dkk)).font(.headline)
                                Text(value.source).font(.caption)
                                Text("Prisdato: \(value.sourceDate) · kurs: \(value.rateDate)").font(.caption2)
                            }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        }
                    }
                }
                TextField("Pris i DKK · valgfri", text: $priceText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                Text("Cardmarket-trend er ikke en standsspecifik NM-pris. Vælg korrekt variant.").font(.footnote).foregroundStyle(.secondary)
            }.padding(18).glassPanel()
            DisclosureGroup("Gradering fra slab-etiket") {
                TextField("Firma: PSA, BGS, CGC eller ARS", text: $info.gradingCompany).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                TextField("Trykt karakter", text: $info.grade).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                TextField("Certifikatnummer", text: $info.certNumber).textFieldStyle(.roundedBorder).frame(minHeight: 56)
                Text("Vi læser kun etiketten. Ingen AI-vurdering af kortets stand.").font(.footnote)
            }.padding(18).frame(minHeight: 56).glassPanel()
        }
    }
    private func lookup() async {
        guard UploadQueue.shared.online else {
            message = "Du er offline. Ret oplysningerne, og gem kortet lokalt. Match og pris kræver net."
            confidence = "Lav"
            return
        }
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
            if let first = quotes.first(where: { $0.source.hasPrefix("TCGplayer") }) ?? (quotes.count == 1 ? quotes.first : nil) {
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
        card.setLogoURL = selected?.set.images?.logo ?? existing?.setLogoURL ?? ""
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
        card.priceRefreshPending = amount == nil && !["JP", "Japanese", "Korean"].contains(info.language)
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
