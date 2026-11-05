# Kortscanner
Dansk iPhone-app til Pokémon-kort. iOS 26. Bygges på GitHub uden Mac.

## Første fase
Kamera med automatisk kantgenkendelse, skarphed og stabilitet, perspektivkorrektion, forside/bagside/nærbillede, import fra Fotos, OCR og Apple Intelligence med regelbaseret fallback, lokal samling og delbar fejllog.

## Installation
1. Åbn fanen Actions i GitHub og det seneste grønne build.
2. Under Artifacts: hent Kortscanner-IPA. Pak zip-filen ud.
3. Åbn Sideloadly på Windows, og forbind din iPhone med USB. Vælg Stol på på telefonen.
4. Træk Kortscanner-unsigned.ipa ind i Sideloadly. Vælg din iPhone og indtast dit Apple-ID direkte i Sideloadly.
5. Tryk Start, og gennemfør selv Apples login.
6. På iPhone: Indstillinger → Generelt → VPN og administration af enhed → din udviklerprofil → Godkend.
7. Aktivér Udviklerfunktion under Indstillinger → Anonymitet & sikkerhed, hvis iOS beder om det, og genstart.
8. Et gratis Apple-ID kræver normalt ny signering efter 7 dage. Brug samme Apple-ID og bundle-ID ved opdatering for at bevare appdata. Slet ikke appen først.

IPA'en er usigneret: GitHub bygger filen; Sideloadly signerer den til din iPhone. Ingen betalt udviklerkonto, App Groups, iCloud eller push bruges.

## Upload / byg selv
Upload indholdet af dette projekt til et GitHub-repo med workflowet under .github/workflows/build.yml. Et push på main starter buildet. Du kan også vælge Actions → Byg Kortscanner IPA → Run workflow. Workflowet genererer det fulde Xcode-projekt med XcodeGen, tester på simulator, bygger til iPhone og pakker Payload/Kortscanner.app som IPA.

## Fejlfinding
Indstillinger → Kopiér log eller Gem fejllog → Del. GitHub-artifactet Kortscanner-fejllogs indeholder compilerlogs, build settings, Info.plist og xcresult. Appens log er afgrænset og gemmes mellem åbninger; billeder, OCR-tekst og nøgler logges ikke.

## Test på telefonen
Afvis kamera → åbn Indstillinger → giv adgang → vend tilbage. Scan et skarpt kort, vend det og scan bagsiden. Prøv japansk tekst og import fra Fotos. Apple Intelligence kan være midlertidigt utilgængelig; OCR virker stadig. Verificér beskæring og kortretning, især i toploader/slab. Scanneren foretrækker kortets indre kanter; hvis den tager slab-kanten, kan billedet tages manuelt.

## Kilder
- https://github.com/actions/runner-images
- https://developer.apple.com/documentation/foundationmodels
- https://developer.apple.com/documentation/vision

## Fase 2
Matchvalg med op til tre billeder, konservativ sikkerhed, DKK-valutakurser cachet pr. dag, valg af prisvariant/kilde, JustTCG med manuelt verificeret produkt-id, mapper, søgning, sortering, status, beskyttede PSA-kort, sletning med fortryd, CSV/JSON og Keychain.

Pokémon TCG API's egen dokumentation oplyser, at tjenesten er under udfasning. Eksisterende nøgler fortsætter ifølge udbyderen til 1. marts 2027; nye registreringer er lukket. Japanske/koreanske kort må ikke få en engelsk udgaves pris automatisk. De kan scannes og gemmes med manuel pris. Cardmarket-trend er ikke NM-specifik; TCGplayer/JustTCG NM er en reference, ikke en standsvurdering. Se prisdato og kursdato ved hvert valg.

Test: scan og vælg mellem match, skift holo-variant, kontrollér DKK og prisdato; gem et kort uden net; filtrér, eksportér, slet og fortryd. Kontrollér, at Moltres PSA og Snorlax PSA ikke kan skifte status.

## Fase 3
Google-login med appendonly og readonly.appcreateddata, eget Kortscanner-album, sekventiel upload (forside, bagside, nærbillede), 401-fornyelse én gang, kontospecifik albumcache, uploadkø gemt i SwiftData og genforsøg ved net/åben app. PhotoKit gemmer billeder lokalt. AI laver danske/engelske salgsudkast; den verificerede DKK-pris tilføjes bagefter. Udkast vises til kontrol og kopieres kun ved dit tryk.

### Google-login: trin for trin
1. Åbn https://console.cloud.google.com/ og opret et projekt, fx Kortscanner.
2. Vælg **API'er og tjenester → Bibliotek**, find **Photos Library API**, og aktivér den.
3. Åbn **Google Auth Platform** (eller OAuth-samtykkeskærm). Angiv appnavn Kortscanner og din kontaktmail.
4. Vælg ekstern målgruppe og testtilstand. Tilføj din egen Google-konto som testbruger.
5. Tilføj tilladelserne **https://www.googleapis.com/auth/photoslibrary.appendonly** og **https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata** under Data Access.
6. Opret en OAuth-klient af typen **iOS**, ikke Web. Bundle-id er **dk.iamfaded90.kortscanner**. Gem det offentlige klient-id, der ender på **.apps.googleusercontent.com**. Ingen client secret skal i appen.
7. Åbn appens **Indstillinger → Google Fotos** på din telefon. Indtast klient-id'et i feltet, og tryk **Gem Google-konfiguration på telefonen**. Det gemmes kun i Keychain, aldrig i repo eller buildvariabler.
8. Appen bruger systemets ASWebAuthenticationSession med PKCE, tilfældig state og et callback-scheme afledt af det klient-id, du indtaster. Der skal ikke bygges en særlig IPA med dine kontodata.
9. Bevar appens bundle-id ved installation med Sideloadly. Google-klientens bundle-id skal svare til den installerede app.
10. Åbn **Indstillinger → Google Fotos → Log ind med Google**, og godkend begge tilladelser. OAuth refresh-token, klient-id og API-nøgler gemmes i telefonens Keychain.
11. Scan et kort. Åbn bagefter **Åbn album i Google Fotos → Del → Opret link**, og send selv linket til dine botter.
12. OAuth i testtilstand kan kræve fornyet login. Hvis Google afviser login: kontrollér testbruger, iOS-klienttype, bundle-id, Photos Library API, scopes og callback-scheme.

Billedbeskrivelserne får det ønskede JSON-øjebliksbillede af kortdata ved upload; senere ændringer af status/pris omskriver ikke allerede uploadede billeder. CSV/JSON-eksport er den fulde aktuelle datakilde. Google-dokumentationen anbefaler menneskeskrevne beskrivelser frem for programmatisk metadata; JSON-beskrivelser bør derfor kontrolleres mod tjenestens gældende vilkår før bred distribution.

Test: efter opsætning upload ét kort, log ud og ind på en anden konto, og upload igen. Afbryd nettet mellem forside og bagside; køen skal fortsætte ved genåbning uden at markere fejlede sider som uploadet. Kontroller lokalt Fotos-album og rækkefølgen i Google-albummet. Google-integration kan ikke sluttestes uden dit klient-id og login.

## Privatliv ved offentligt build
Repoet indeholder kun genereret kildekode og tests. Ingen IPA, kortbilleder, backups, samlingsdata, API-nøgler, OAuth-klient-id'er eller tokens må committes. Builds indeholder ingen personlige loginoplysninger. IPA og øvrige artifacts slettes automatisk efter én dag. Samlingen er lokal. Google kræver dit eget OAuth-projekt og din egen konto; opret den som testbruger i Google Cloud. Offentlig kildekode kan også bygges af andre, men giver dem ingen adgang til dine data. En offentlig usigneret IPA er ikke en personlig adgangslås; din telefon og OAuth-tilladelser beskytter dine data.
