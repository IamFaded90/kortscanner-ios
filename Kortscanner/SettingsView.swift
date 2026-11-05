import SwiftUI
import SwiftData
import FoundationModels
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var cards: [CardItem]
    @ObservedObject private var log = DebugLog.shared
    @ObservedObject private var google = GooglePhotosService.shared
    @ObservedObject private var queue = UploadQueue.shared
    @ObservedObject private var backup = BackupManager.shared
    @AppStorage("autoGoogleUpload") private var autoGoogle = true
    @AppStorage("saveLocalPhotos") private var localPhotos = true
    @AppStorage("appearance") private var appearance = "Mørk"
    @AppStorage("holoEnabled") private var holo = true
    @AppStorage("scanSlabMode") private var slabMode = false
    @AppStorage("gradingThreshold") private var gradingThreshold = 1000.0
    @State private var googleClient = Keychain.get("googleClientID")
    @State private var pokemonKey = Keychain.get("pokemonAPI")
    @State private var justKey = Keychain.get("justTCG")
    @State private var export: URL?
    @State private var message = ""
    @State private var showClear = false
    @State private var showClearLog = false
    @State private var showFolder = false
    @State private var showImport = false
    @State private var showRestore = false
    @State private var imported: BackupEnvelope?
    @State private var tests: [String: Bool] = [:]
    @State private var explanations: [String: String] = [:]
    @State private var testing = false
    private var activeCards: [CardItem] { cards.filter { $0.deletedAt == nil } }
    var body: some View {
        NavigationStack {
            List {
                Section("Din samling") {
                    NavigationLink { accounts } label: { settingLabel("Konti", "person.crop.circle") }
                    NavigationLink { albums } label: { settingLabel("Album", "photo.on.rectangle") }
                    NavigationLink { backups } label: { settingLabel("Backup", "externaldrive") }
                }
                Section("Din app") {
                    NavigationLink { looks } label: { settingLabel("Udseende og scanning", "paintpalette") }
                    NavigationLink { diagnostics } label: { settingLabel("Test og log", "stethoscope") }
                    NavigationLink { dataSettings } label: { settingLabel("Data og fortryd", "tray.full") }
                }
                Section {
                    Text("Kort og priser gemmes på din iPhone. Apple Intelligence behandler tekst lokalt. Valgfrie prisopslag sender kortets søgeord til priskilden; Google Fotos modtager kun scanninger, når du har logget ind og slået upload til.").font(.footnote).foregroundStyle(.secondary)
                }
            }.scrollContentBackground(.hidden).background(Theme.bg).navigationTitle("Indstillinger")
        }
        .sheet(isPresented: $showFolder) {
            BackupFolderPicker { url in
                do { try backup.chooseFolder(url); try backup.write(context) }
                catch { message = "Backupmappen kunne ikke bruges. Prøv at vælge den igen." }
                showFolder = false
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            do { imported = try backup.read(result.get()); showRestore = true }
            catch { message = "Filen kunne ikke læses som en Kortscanner-backup." }
        }
        .confirmationDialog("Gendan \(imported?.cards.filter { $0.deletedAt == nil }.count ?? 0) kort fra backup?", isPresented: $showRestore, titleVisibility: .visible) {
            Button("Gendan backup") {
                if let imported {
                    do { try backup.restore(imported, context: context); message = backup.message }
                    catch { message = "Gendannelsen kunne ikke fuldføres." }
                }
            }
        } message: { Text("Kort med samme id opdateres. Andre eksemplarer bevares. Der gemmes en sikkerhedskopi først, og du kan fortryde.") }
        .confirmationDialog("Ryd alle \(activeCards.count) kort fra samlingen?", isPresented: $showClear, titleVisibility: .visible) {
            Button("Ryd samlingen", role: .destructive) {
                let affected = activeCards
                do {
                    try backup.write(context, safetyCopy: true)
                    affected.forEach { $0.deletedAt = Date() }
                    try CollectionMaintenance.commit(context)
                    ActionHistory.shared.record("rydning af samling", undo: { affected.forEach { $0.deletedAt = nil }; CollectionMaintenance.saveAfterUndo(context) }, redo: { affected.forEach { $0.deletedAt = Date() }; CollectionMaintenance.saveAfterUndo(context) })
                    message = "Samlingen er ryddet. Du kan fortryde."
                } catch { context.rollback(); message = "Samlingen kunne ikke ryddes." }
            }
        } message: { Text("Billeder i Fotos og Google Fotos slettes ikke. Den lokale ændring kan fortrydes.") }
        .confirmationDialog("Ryd fejlloggen?", isPresented: $showClearLog, titleVisibility: .visible) {
            Button("Ryd log", role: .destructive) {
                let previous = log.lines
                log.clear()
                ActionHistory.shared.record("rydning af log", undo: { log.restore(previous) }, redo: { log.clear() })
            }
        }
    }
    private func settingLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline).frame(minHeight: 56)
    }
    private var accounts: some View {
        Form {
            Section("Google · kun på denne telefon") {
                SecureField("Dit iOS OAuth-klient-id", text: $googleClient).textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 56)
                Button("Gem Google-konfiguration") {
                    do {
                        google.signOut()
                        try Keychain.set(googleClient.trimmingCharacters(in: .whitespacesAndNewlines), key: "googleClientID")
                        message = "Klient-id er gemt i Keychain på telefonen."
                    } catch { message = "Konfigurationen kunne ikke gemmes." }
                }.frame(minHeight: 56)
                if google.signedIn {
                    Button("Log ud af Google") { google.signOut() }.disabled(queue.running).frame(minHeight: 56)
                } else {
                    Button("Log ind med Google") { Task {
                        do { try await google.signIn(); await queue.process(force: true) }
                        catch { message = error.localizedDescription }
                    }}.disabled(!google.configured).frame(minHeight: 56)
                }
                Text(google.signedIn ? "Logget ind med din egen Google-konto." : "Følg Google-guiden i README. Ingen loginoplysninger skal ind i GitHub.").font(.footnote)
            }
            Section("Priskilder · valgfrit") {
                SecureField("Pokémon TCG API-nøgle", text: $pokemonKey).textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 56)
                SecureField("JustTCG API-nøgle", text: $justKey).textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 56)
                Button("Gem API-nøgler i Keychain") {
                    do {
                        try Keychain.set(pokemonKey.trimmingCharacters(in: .whitespacesAndNewlines), key: "pokemonAPI")
                        try Keychain.set(justKey.trimmingCharacters(in: .whitespacesAndNewlines), key: "justTCG")
                        message = "Nøglerne er gemt sikkert på telefonen."
                    } catch { message = "Nøglerne kunne ikke gemmes." }
                }.frame(minHeight: 56)
                Text("Pokémon TCG API er under udfasning. Scanning og samling virker også uden net og API-nøgler.").font(.footnote)
            }
            feedback
        }.navigationTitle("Konti")
    }
    private var albums: some View {
        Form {
            Section("Google Fotos") {
                Toggle("Upload automatisk efter kontrol", isOn: $autoGoogle).frame(minHeight: 56)
                Button(queue.running ? "Uploader …" : "Prøv uploadkø igen") { Task { await queue.process(force: true) } }.disabled(queue.running || !google.signedIn).frame(minHeight: 56)
                if let url = google.albumURL { Link("Åbn album i Google Fotos", destination: url).frame(minHeight: 56) }
                Text("Åbn albummet, og vælg selv Del › Opret link. Upload fortsætter ved netforbindelse og mens appen er åben. Batch-kort venter på din kontrol først.").font(.footnote)
                Text("\(activeCards.filter { $0.pendingUpload || $0.googleAccount != google.accountID }.count) kort venter. \(queue.message)").font(.footnote)
            }
            Section("Fotos på iPhone") {
                Toggle("Gem i albummet Kortscanner", isOn: $localPhotos).frame(minHeight: 56)
                Button("Prøv lokal fotolagring igen") { Task { await queue.process(force: true) } }.frame(minHeight: 56)
            }
            feedback
        }.navigationTitle("Album")
    }
    private var backups: some View {
        Form {
            Section("Automatisk backup") {
                Label(backup.externalFolderChosen ? "Ekstern mappe er valgt" : "Vælg en mappe uden for appen", systemImage: backup.externalFolderChosen ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(backup.externalFolderChosen ? .green : .orange)
                Text("Vælg fx en mappe i iCloud Drive eller på et eksternt drev i Filer. Det kræver ingen iCloud-funktion i appen. En kopi under På min iPhone/Kortscanner forsvinder, hvis appen slettes.").font(.footnote)
                Button("Vælg backupmappe i Filer") { showFolder = true }.frame(minHeight: 56)
                Button("Tag backup nu") {
                    do { try backup.write(context); message = backup.message }
                    catch { message = "Backup kunne ikke gemmes. Vælg mappen igen." }
                }.frame(minHeight: 56)
                Button("Gendan fra JSON-backup") { showImport = true }.frame(minHeight: 56)
                if let date = backup.lastBackup { Text("Sidste backup: \(date.formatted(date: .abbreviated, time: .shortened))").font(.footnote) }
                Text(backup.message).font(.footnote)
            }
            Section {
                Text("Backup indeholder alle eksemplarer, billeder, priser og historik. Ingen API-nøgler eller Google-login kommer med. Gendannelse kræver en backup fra denne app, højst 500 MB.").font(.footnote)
            }
            feedback
        }.navigationTitle("Backup")
    }
    private var looks: some View {
        Form {
            Section("Udseende") {
                Picker("Tema", selection: Binding(get: { appearance }, set: { value in
                    let old = appearance; appearance = value
                    ActionHistory.shared.record("tema", undo: { appearance = old }, redo: { appearance = value })
                })) { ForEach(["Mørk", "Lys", "System"], id: \.self) { Text($0) } }.frame(minHeight: 56)
                Toggle("Diskret holo-effekt", isOn: $holo).frame(minHeight: 56)
                Text("Reducer bevægelse i iPhone-indstillingerne slår bevægelseseffekter fra.").font(.footnote)
            }
            Section("Scanning") {
                Toggle("Slab/toploader · bevar hele etiketten", isOn: $slabMode).frame(minHeight: 56)
                Text("Normal tilstand retter kortets kanter ud. Slab-tilstand bevarer hele kamerabilledet, så firma, karakter og certifikat kan læses.").font(.footnote)
                Stepper(value: $gradingThreshold, in: 100...10000, step: 100) {
                    Text("Undersøg gradering fra \(dkk(gradingThreshold))")
                }.frame(minHeight: 56)
            }
            Section("Siri og Kontrolcenter") {
                Text("Siri/Genveje: Hvad er min samling værd? læser de gemte tal direkte fra appen. Føj Scan et kort til Kontrolcenter, eller vælg den som Genvej under iPhones Handlingsknap.").font(.footnote)
            }
            feedback
        }.navigationTitle("Udseende og scanning")
    }
    private var diagnostics: some View {
        Form {
            Section("Test") {
                Button(testing ? "Tester …" : "Test kamera, Google, API og AI") { Task { await runTests() } }.disabled(testing).frame(minHeight: 56)
                ForEach(tests.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(key, systemImage: tests[key] == true ? "circle.fill" : "circle.fill").foregroundStyle(tests[key] == true ? .green : .red)
                        Text(explanations[key] ?? "").font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
            }
            Section("Log") {
                Button("Kopiér log") { UIPasteboard.general.string = log.lines.joined(separator: "\n"); message = "Loggen er kopieret." }.frame(minHeight: 56)
                Button("Del fejllog") { do { export = try log.export() } catch { message = "Loggen kunne ikke eksporteres." } }.frame(minHeight: 56)
                if let export { ShareLink("Åbn delingsark", item: export).frame(minHeight: 56) }
                NavigationLink("Vis log") {
                    ScrollView { Text(log.lines.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).padding() }.navigationTitle("Fejllog")
                }.frame(minHeight: 56)
                Button("Ryd log", role: .destructive) { showClearLog = true }.frame(minHeight: 56)
            }
            feedback
        }.navigationTitle("Test og log")
    }
    private var dataSettings: some View {
        Form {
            Section {
                Button("Fortryd seneste lokale ændring") { ActionHistory.shared.undo() }.frame(minHeight: 56)
                Button("Gentag ændring") { ActionHistory.shared.redo() }.frame(minHeight: 56)
                Button("Ryd hele samlingen", role: .destructive) { showClear = true }.frame(minHeight: 56)
                Text("Lokale kortændringer kan fortrydes. Uploadede billeder fjernes ikke automatisk fra dine fotoalbums.").font(.footnote)
            }
            feedback
        }.navigationTitle("Data og fortryd")
    }
    @ViewBuilder private var feedback: some View { if !message.isEmpty { Section { Text(message) } } }
    private var aiAvailable: Bool { if case .available = SystemLanguageModel.default.availability { return true }; return false }
    private func runTests() async {
        testing = true
        let camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        tests = ["Kamera": camera, "Apple Intelligence": aiAvailable, "Ekstern backup": backup.externalFolderChosen]
        explanations = ["Kamera": camera ? "Kameraadgang er slået til." : "Giv Kortscanner kameraadgang i iPhone-indstillingerne.",
                        "Apple Intelligence": aiAvailable ? "Modellen er klar på din iPhone." : "Slå Apple Intelligence til, og vent på modeldownload. OCR virker stadig.",
                        "Ekstern backup": backup.externalFolderChosen ? "En mappe er valgt. Test også med Tag backup nu." : "Vælg en ekstern mappe i Backup for at beskytte mod afinstallation."]
        do {
            _ = try await CardAPI.search(CardInfo(name: "Pikachu", number: "25"))
            tests["Pokémon API"] = true; explanations["Pokémon API"] = "Priskataloget svarer."
        } catch { tests["Pokémon API"] = false; explanations["Pokémon API"] = "Tjek net og API-nøgle. Kataloget er under udfasning."; DebugLog.shared.error("Diagnose: Pokémon API fejlede") }
        if google.signedIn {
            do { try await google.test(); tests["Google Fotos"] = true; explanations["Google Fotos"] = "Login og adgang til appens album virker." }
            catch { tests["Google Fotos"] = false; explanations["Google Fotos"] = "Log ind igen, og kontrollér begge Fotos-tilladelser." }
        } else { tests["Google Fotos"] = false; explanations["Google Fotos"] = "Indtast dit klient-id i Konti, og log ind." }
        testing = false
    }
}
