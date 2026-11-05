# Kortscanner
Dansk iPhone-app til Pokémon-kort. iOS 18.1 eller nyere (inklusive iOS 18.1.1). Bygges på GitHub uden Mac.

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

## Fase 4 og tilføjelser
- Kameraet er første fane. Automatisk optagelse bruger Vision-rektangler, bevægelsesstabilitet og BGRA-skarphed. Manuel udløser og Fotos-import er tilgængelige.
- Batch gemmer hvert eksemplars billeder i SwiftData med det samme og genkender tekst bagefter. Forside/bagside kan scannes uden mellemtryk. Batch-kort er markeret til manuel kontrol, før Google-upload og sikker matchpris.
- Hvert eksemplar har egne billeder, stand, status og pris. Samme identitet grupperes med x2/x3. Listevisningen kan foldes ud; gitteret åbner eksemplarer.
- DKK-prishistorik gemmes ved opdatering. Graf pr. eksemplar samt samlingsgraf fra registrerede værdier. Ændring siden i går omfatter også nye/solgte/slettede eksemplarer; det er ikke et beregnet investeringsafkast.
- Stand-tjek viser beskårne hjørner og kanter fra begge sider med zoom. Ingen AI-stand eller karakter. Du vælger NM/LP/MP mv.
- Noten om PSA er kun en regel ved din valgte raw-værditærskel; den beregner ikke gradering, gevinst eller forventet karakter.
- Samlingschat bruger Apple Intelligence og beregnede fakta, med lokal fallback. Salgsforslag udelukker beskyttede PSA-kort. Alle AI-tekster skal kontrolleres.
- Siri/Genveje: Scan et kort og Hvad er min samling værd? Live Activity kan vise batch-status uden push.
- Mørk blå baggrund som standard, gul accent, blå sekundærfarve, grøn/orange/grå status, glas-paneler, stor tekst og støtte for Reducer bevægelse. Holo-effekten er visuel og siger intet om kortets faktiske variant.

### Automatisk backup og gendannelse
1. Åbn **Indstillinger → Backup → Vælg backupmappe i Filer**.
2. Vælg en mappe uden for Kortscanner, fx iCloud Drive eller et tilsluttet drev. Det er normal Filer-adgang og kræver ingen iCloud-container i appen.
3. Tryk **Tag backup nu**, og kontrollér i Filer at **Kortscanner-seneste.json** findes. Filen indeholder billeder som base64 samt alle eksemplarer og historik, men ingen nøgler eller login.
4. Appen gemmer automatisk efter lokale samlingsændringer og ved baggrundsskift. Den beholder også dagens første kopi som **Kortscanner-ÅÅÅÅ-MM-DD.json**. Gamle dagskopier slettes ikke automatisk.
5. Hvis appen geninstalleres: vælg **Gendan fra JSON-backup**, vælg filen, og bekræft. Samme id opdateres; ekstra eksemplarer bevares. Du kan fortryde gendannelsen.
6. Vælg backupmappen igen efter geninstallation, og indtast dine nøgler/log ind igen. Loginoplysninger er ikke i backup.
7. Hvis ingen ekstern mappe er valgt, laves kun en lokal kopi i appens Dokumenter, synlig under På min iPhone/Kortscanner. Denne kopi overlever **ikke** sletning af appen. En 7-dages fornyelse i Sideloadly kræver normalt ikke afinstallation.
8. Gendannelse accepterer backupversion 1, højst 10.000 poster og en JSON-fil under 500 MB. Store billedsamlinger skal derfor sikkerhedskopieres og kontrolleres løbende.

### Offline
Kamera, OCR, lokal samling, chat-fallback og manuel pris virker uden net. Apple Intelligence virker lokalt, når modellen allerede er hentet og tilgængelig. Genkendte API-kort med en ventende pris genforsøges, når appen er åben og nettet vender tilbage. Ukendte eller tvetydige kort kræver dit matchvalg; de får aldrig automatisk en gættet pris. Google-upload ligger i en vedvarende kø og fortsætter i appen; der bruges ingen baggrundspush.

### Siri, Kontrolcenter og Handlingsknap
Der er ingen hjemmeskærmswidget.
- I Genveje finder du **Kortscanner → Hvad er min samling værd?** Genvejen læser SwiftData direkte, summerer ikke-solgte eksemplarer og fortæller, hvor mange der mangler pris. Det er de senest gemte priser, ikke et nyt netopslag og ikke et AI-gæt.
- Åbn **Kontrolcenter → Tilføj en betjeningsfunktion**, find **Kortscanner → Scan et kort**. Kontrollen åbner appens kamera.
- På iPhone 17 Pro Max: **Indstillinger → Handlingsknap → Genvej → Scan et kort** under Kortscanner.
- Live Activity vises under batch, når iOS tillader det. Ingen push eller App Groups bruges.
- Extensionen med Kontrolcenter og Live Activity skal være bevaret ved signering i Sideloadly. Hvis gratis signering afviser extensionen, virker hovedappen og Siri-genvejene stadig; det skal kontrolleres på din telefon.

### Fortryd og sletning
Lokale ændringer (nye kort, pris, stand, status, sletning, samlingsrydning og gendannelse) har fortryd/gentag i den aktuelle session, op til ti handlinger. Sletning kræver bekræftelse. Sletning af et eksemplar er lokal og kan fortrydes. Foto-upload kan ikke trækkes tilbage af en appendonly-app; billeder i Fotos og Google Fotos slettes kun manuelt af dig. Afviste eller usikre data bliver ikke automatisk solgt.

### Sluttest på din iPhone
Fase 1: test kameraramme, auto-optagelse, japansk OCR, slab-etiket, afvis/tillad kamera og offline scanning.
Fase 2: vælg match og holo-variant, kontrollér DKK-kurs/prisdato, gem forskellige eksemplarer og test PSA-låsen.
Fase 3: konfigurer Google, test lokalt album, Google-album, billedrækkefølge, upload efter netafbrydelse og salgsudkast uden publicering.
Fase 4: scan tre kort i batch, kontrollér dem i Samling, redigér pris og se historik, test stand-zoom, gendan en backup, fortryd sletning, prøv Siri/chat/Live Activity og Kontrolcenter/Handlingsknap. Test også stor tekst, lyst tema og Reducer bevægelse.

GitHub-simulatoren tester parser, beskyttede kort, identitet for eksemplarer, prisregistrering og backup-rundtur. Kamera, sensorer, Apple Intelligence og OAuth skal desuden testes på en fysisk telefon. At et IPA-build er grønt dokumenterer kompilering og tests, ikke en fuld fysisk enhedstest.

Buildet forsøger også at tage simulatorbilleder af Samling og Indstillinger i lyst og mørkt tema. De er kun tomme testvisninger og indeholder ingen personlige samlingsdata. Artifacts udløber efter én dag. Backup- og prisgrafdata skabes af faktiske lokale gemninger; der indsættes ingen fiktiv samling.

## iOS 18.1.1 og nyere
- Samme app og lokale samling virker fra iOS 18.1. Installer IPA med Sideloadly som beskrevet ovenfor.
- På iOS 18 bruges Vision OCR og regler til kortgenkendelse. Du kan rette oplysninger og vælge et af de foreslåede kort.
- Salgsudkast laves med danske/engelske skabeloner, og samlingschatten besvarer de foreslåede spørgsmål med beregnede gemte tal. Andre spørgsmål viser en faktuel oversigt.
- På iOS 26 bruges Foundation Models automatisk, når modellen er tilgængelig. Appens modeladgang findes ikke på iOS 18, selv hvis telefonen har Apple Intelligence.
- Glaspaneler bruger materialebaggrunde på iOS 18 og Liquid Glass på iOS 26. Siri, Handlingsknappen, Kontrolcenter og Live Activity bevares. Der er ingen hjemmeskærmswidget.
- Backup, billeder, priser, salg, Google Fotos og offlinefunktioner bevares. Google kræver fortsat dit eget klient-id og login.
- Test på telefonen: scan forside/bagside, gem og genåbn et kort, prøv samlingsspørgsmål og et salgsudkast, og start batch for at se Live Activity. Prøv også Scan et kort fra Genveje/Kontrolcenter.

## Billedværktøjer og scanningstest
- Fotos gemmes i kameraets retning. OCR kan undersøge en anden retning uden at ændre originalen.
- Efter scanning: vælg Forside/Bagside/Nummer og brug Drej 90°. Fortryd rotation er lokal indtil Gem. På gemte kort: Drej billedet 90°; brug appens Fortryd for at vende ændringen tilbage.
- Vaterpasset viser telefonens vinkel fra vandret. Læg kortet fladt; en grøn indikator betyder højst 3°. Det måler telefonen, ikke kortets hældning, og ændrer ikke automatisk billedet.
- Mål centrering findes i kortets detaljer. Placér gul ramme på kortets yderkanter og blå ramme på trykkets indre kanter. Vælg forside eller bagside og justér de fire linjer med skyderne. Startlinjerne er ikke en analyse. Forholdene vises først efter justering.
- Centrering er en manuel geometrisk måling i billedet, ingen AI-stand eller karakter. Skæve fotos, blank plast og full-art uden tydelig indre kant kan ikke give en sikker måling. Kopiér resultatet, hvis du vil gemme det; appen gemmer ikke linjerne.
- ACE Grading er tilføjet til OCR af firma, trykt karakter og certifikat. Ulæselige etiketter kan stadig rettes manuelt. ACE er ikke automatisk låst til Beholder; beskyttelsen gælder fortsat Moltres PSA og Snorlax PSA.
- Hvis genkendelse fejler, åbnes rettelser automatisk. Skriv sætnavn og kortnummer, fjern et forkert OCR-navn, og tryk Find match igen. Sætnavnet bruges nu i selve katalogsøgningen. Japanske/koreanske kort skal stadig gemmes manuelt i dette engelske katalog.
- Google Fotos kræver et iOS OAuth-klient-id. En manglende konfiguration er ikke en uploadfejl. Åbn Konti → Hjælp: forbind Google Fotos og følg guiden; brug bundle-id'et fra den installerede app. Ingen klient-id'er skal ind i GitHub.
- En rotation af et allerede uploadet foto ændrer kun den lokale kopi; et tidligere foto i Google Fotos ændres ikke.
- Test på telefonen: scan et kort, kontrollér begge sider, drej og fortryd, gem og genåbn. Kontroller vaterpasset over et fladt bord. Mål et kort med kendte kantbredder og prøv begge sider. Scan en ACE-etiket, og prøv sætnavn + nummer ved manglende match.
