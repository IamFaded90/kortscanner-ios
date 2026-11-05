import Foundation
import SwiftUI

enum GoogleDiagnostics {
    static func message(status: Int, code: String) -> String {
        switch code {
        case "invalid_client", "unauthorized_client":
            return "Google genkender ikke klient-id'et. Opret en OAuth-klient af typen iOS, og gem hele klient-id'et i Konti."
        case "redirect_uri_mismatch":
            return "Google afviser returadressen. Kontrollér, at klient-id'et er til iOS, og at det er kopieret uden ekstra tegn."
        case "invalid_grant":
            return "Google-login er udløbet eller tilbagekaldt. Log ud og ind igen."
        case "access_denied", "org_internal":
            return "Google afviste adgangen. Tilføj din egen konto som testbruger i Google Cloud, og godkend begge Fotos-tilladelser."
        case "SERVICE_DISABLED", "accessNotConfigured":
            return "Google Photos Library API er ikke slået til i dit Google Cloud-projekt. Aktivér den, og prøv igen."
        case "ACCESS_TOKEN_SCOPE_INSUFFICIENT", "insufficientPermissions":
            return "Google mangler Fotos-tilladelser. Log ud og ind igen, og godkend både upload og læsning af appens egne billeder."
        default:
            if status == 403 { return "Google nægtede adgang (403). Kontrollér testbruger, Photos Library API og begge Fotos-tilladelser i opsætningsguiden." }
            if status == 429 { return "Google har begrænset antallet af kald. Uploadkøen prøver igen senere." }
            return "Google kunne ikke fuldføre forbindelsen (\(status)). Prøv igen, og brug Test og log."
        }
    }
    static let safeCodes: Set<String> = ["invalid_client", "unauthorized_client", "redirect_uri_mismatch",
        "invalid_grant", "access_denied", "org_internal", "SERVICE_DISABLED", "accessNotConfigured",
        "ACCESS_TOKEN_SCOPE_INSUFFICIENT", "insufficientPermissions", "invalid_request"]
}

struct GoogleSetupView: View {
    private var bundleID: String { Bundle.main.bundleIdentifier ?? "dk.iamfaded90.kortscanner" }
    var body: some View {
        List {
            Section("1 · Opret projekt og API") {
                Text("Opret et projekt i Google Cloud. Find Google Photos Library API i API-biblioteket, og aktivér den.")
                Link("Åbn Photos Library API i Google Cloud", destination: URL(string: "https://console.cloud.google.com/apis/library/photoslibrary.googleapis.com")!).frame(minHeight: 56)
            }
            Section("2 · Tillad din konto") {
                Text("Under Google Auth Platform: konfigurér samtykke, vælg External og Testing, og tilføj din egen Google-konto som testbruger. Tilføj begge Fotos-tilladelser under Data Access.")
                Link("Åbn Google Auth Platform", destination: URL(string: "https://console.cloud.google.com/auth/overview")!)
                Button("Kopiér begge Fotos-tilladelser") {
                    UIPasteboard.general.string = "https://www.googleapis.com/auth/photoslibrary.appendonly\nhttps://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata"
                }
            }
            Section("3 · Opret iOS-klient") {
                Text("Opret en OAuth-klient af typen iOS. Brug bundle-id'et nedenfor fra denne installerede app. App Store-id og Team-id kan være tomme. Aktivér ikke App Check til denne Sideloadly-test.")
                Link("Åbn OAuth-klienter", destination: URL(string: "https://console.cloud.google.com/auth/clients")!)
                Text(bundleID).font(.footnote.monospaced()).textSelection(.enabled)
                Button("Kopiér appens bundle-id") { UIPasteboard.general.string = bundleID }.frame(minHeight: 56)
            }
            Section("4 · Forbind Kortscanner") {
                Text("Kopiér hele klient-id'et fra Google Cloud. Gå tilbage til Forbindelser, tryk Indsæt, og vælg Gem og log ind med Google. Godkend begge Fotos-tilladelser.")
                Text("Klient-id og login gemmes kun i Keychain på telefonen. Del aldrig tokens eller adgangskoder i fejlloggen. I testtilstand kan Google kræve nyt login efter 7 dage.").font(.footnote)
            }
            Section("Hvis Google viser en fejl") {
                Text("Notér fejlens kode. Ved access_denied skal din konto være testbruger. Ved invalid_client skal klienttypen være iOS. Ved 403 skal API og begge tilladelser kontrolleres. Kør derefter Indstillinger → Test og log.")
            }
        }.navigationTitle("Forbind Google Fotos").navigationBarTitleDisplayMode(.inline)
    }
}
