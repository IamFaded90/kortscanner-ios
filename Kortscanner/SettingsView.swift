import SwiftUI
import SwiftData
import FoundationModels
import AVFoundation

struct SettingsView: View {
    @ObservedObject private var google = GooglePhotosService.shared
    @ObservedObject private var queue = UploadQueue.shared
    @AppStorage("autoGoogleUpload") private var autoGoogle = true
    @AppStorage("saveLocalPhotos") private var localPhotos = true
    @Environment(\.modelContext) private var context
    @Query private var cards: [CardItem]
    @ObservedObject private var log = DebugLog.shared
    @State private var googleClient = Keychain.get("googleClientID")
    @State private var pokemonKey = Keychain.get("pokemonAPI")
    @State private var justKey = Keychain.get("justTCG")
    @State private var export: URL?
    @State private var message = ""
    @State private var showClear = false
    @State private var tests: [String: Bool] = [:]
    @State private var testing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Google Fotos") {
                    SecureField("Dit Google iOS OAuth-klient-id", text: $googleClient).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Gem Google-konfiguration på telefonen") {
                        do {
                            google.signOut()
                            try Keychain.set(googleClient.trimmingCharacters(in: .whitespacesAndNewlines), key: "googleClientID")
                            message = "Google-klient-id er gemt i telefonens Keychain."
                        } catch { message = error.localizedDescription }
                    }
                    Text(google.signedIn ? "Du er logget ind" : google.configured ? "Klar til Google-login" : "Følg Google-guiden i README for at aktivere login.").font(.footnote)
                    if google.signedIn {
                        Button("Log ud af Google") { google.signOut() }.disabled(queue.running)
                    } else {
                        Button("Log ind med Google") { Task {
                            do { try await google.signIn(); await queue.process(force: true) }
                            catch { message = error.localizedDescription }
                        }}.disabled(!google.configured)
                    }
                    Toggle("Upload automatisk", isOn: $autoGoogle)
                    if let url = google.albumURL { Link("Åbn album i Google Fotos", destination: url) }
                    Text("Åbn albummet, og vælg selv Del › Opret link.").font(.footnote)
                    Button(queue.running ? "Uploader …" : "Prøv uploadkø igen") { Task { await queue.process(force: true) } }.disabled(queue.running || !google.signedIn)
                    let pending = cards.filter { $0.deletedAt == nil && ($0.pendingUpload || $0.googleAccount != google.accountID) }.count
                    Text("\(pending) kort venter. \(queue.message)").font(.footnote)
                    Text("Upload prøves igen ved netforbindelse og hvert minut, mens appen er åben.").font(.caption)
                }
                Section("Album på iPhone") {
                    Toggle("Gem billeder i Fotos-albummet Kortscanner", isOn: $localPhotos)
                    Button("Prøv lokal fotolagring igen") { Task { await queue.process(force: true) } }
                }
                Section("Apple Intelligence") {
                    Label(caseAvailable ? "Klar på denne iPhone" : "Bruger almindelig tekstgenkendelse", systemImage: caseAvailable ? "checkmark.circle.fill" : "info.circle")
                    Text("Kortdata behandles på din iPhone. AI kan tage fejl; kontrollér kort og pris.").font(.footnote)
                }
                Section("API-nøgler · valgfrit") {
                    SecureField("Pokémon TCG API-nøgle", text: $pokemonKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("JustTCG API-nøgle", text: $justKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Gem nøgler sikkert") {
                        do {
                            try Keychain.set(pokemonKey.trimmingCharacters(in: .whitespacesAndNewlines), key: "pokemonAPI")
                            try Keychain.set(justKey.trimmingCharacters(in: .whitespacesAndNewlines), key: "justTCG")
                            message = "Nøglerne er gemt i Keychain."
                        } catch { message = error.localizedDescription }
                    }
                    Text("Pokémon TCG API er under udfasning og kan kræve en eksisterende nøgle. Samlingen virker også uden API.").font(.footnote)
                }
                Section("Fejlfinding") {
                    Button(testing ? "Tester …" : "Test") { Task { await runTests() } }.disabled(testing)
                    ForEach(tests.keys.sorted(), id: \.self) { key in
                        Label(key, systemImage: tests[key] == true ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(tests[key] == true ? .green : .red)
                    }
                    Button("Kopiér log") { UIPasteboard.general.string = log.lines.joined(separator: "\n"); message = "Loggen er kopieret." }
                    Button("Gem fejllog") {
                        do { export = try log.export() }
                        catch { message = "Loggen kunne ikke eksporteres." }
                    }
                    if let export { ShareLink("Del fejllog", item: export) }
                    NavigationLink("Vis log") {
                        ScrollView { Text(log.lines.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).padding() }.navigationTitle("Fejllog")
                    }
                }
                Section("Data") {
                    Button("Ryd hele samlingen", role: .destructive) { showClear = true }
                    Text("Swipe-slettede kort kan fortrydes i Samling. Denne knap fjerner alle lokale kort permanent. Billeder i Fotos og Google Fotos bevares.").font(.footnote)
                }
                if !message.isEmpty { Section { Text(message) } }
                Section { Text("Dine kort gemmes lokalt. Fejlloggen indeholder ingen billeder, OCR-tekst eller API-nøgler.").font(.footnote) }
            }.navigationTitle("Indstillinger")
            .confirmationDialog("Slet alle \(cards.count) kort?", isPresented: $showClear, titleVisibility: .visible) {
                Button("Slet alle", role: .destructive) {
                    for card in cards { context.delete(card) }
                    do { try context.save(); message = "Den lokale samling er ryddet."; DebugLog.shared.info("Samling ryddet") }
                    catch { context.rollback(); message = "Samlingen kunne ikke ryddes." }
                }
            }
        }
    }
    private var caseAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    private func runTests() async {
        testing = true
        tests = ["Kamera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized, "Apple Intelligence": caseAvailable]
        do {
            _ = try await CardAPI.search(CardInfo(name: "Pikachu", number: "25"))
            tests["Pokémon API"] = true
        } catch { tests["Pokémon API"] = false; DebugLog.shared.error("Diagnose: Pokémon API fejlede") }
        do { _ = try await ExchangeRates.shared.rate("EUR"); tests["DKK-valutakurs"] = true }
        catch { tests["DKK-valutakurs"] = false }
        if google.signedIn {
            do { try await google.test(); tests["Google-login og Fotos"] = true }
            catch { tests["Google-login og Fotos"] = false }
        } else { tests["Google-login og Fotos"] = false }
        testing = false
    }
}
