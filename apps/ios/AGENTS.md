# Arbeitsanweisungen für Quant iOS

## Geltungsbereich

Diese Datei ergänzt die Regeln im Repository-Root für `apps/ios`.

## Aufnahme und Schnellzugriff

- Der Action-Button beziehungsweise App Intent öffnet unmittelbar die Kamera,
  auch wenn Quant bereits im Vordergrund ist.
- Vor dem Sprung zur Kamera müssen präsentierte Mahlzeitendetails,
  Review-Sheets, Dialoge und andere Modals zuverlässig geschlossen werden.
- In der Aufnahmeansicht steht unten eine standardmäßig eingeklappte Karte
  „Details“ mit dem Zeitpunkt. Eine Mahlzeitenart wird nicht abgefragt; neue
  Mahlzeiten erhalten den neutralen Kategoriewert `unspecified`.
- Mahlzeiten können gelöscht werden. Dabei auch zugehörige Analysedaten und von
  der App verwaltete Bilddateien konsistent entfernen.

## Heute, Mahlzeiten und Analyseverlauf

- Für Tag, Woche und Monat steht die kcal-Summe rechts in der jeweiligen
  Abschnittsüberschrift. Vorläufige Summen mit `~` markieren; ohne Energiewert
  `— kcal` anzeigen.
- Der Analyseverlauf bewahrt Revisionen und tatsächliche Modellaufrufe
  nachvollziehbar und aufklappbar auf.

## OpenRouter-Einstellungen

- Die Modellauswahl ist ein verständliches Menü beziehungsweise Dropdown. Die
  App lädt geeignete Modelle über die OpenRouter-Model-API und bietet zusätzlich
  eine manuelle Modellkennung als fortgeschrittene Option an.
- Nur Modelle anbieten, die die für Quant erforderlichen Bild- und
  strukturierten Ausgaben unterstützen. Die Liste wird nach der von OpenRouter
  gelieferten Popularitätsinformation sortiert; diese Herkunft in der UI
  verständlich machen.
- Den Nutzer darauf hinweisen, dass normalerweise ein Modellaufruf anfällt, bei
  Tellerfotos ohne erkanntes Etikett oder belastbare Maßangabe drei Aufrufe
  erfolgen und bei einer fehlerhaften Antwort einmalig ein Korrekturaufruf
  folgen kann.
- Die gewählte Modellkennung darf in UserDefaults gespeichert werden.

## Datenhaltung und Migrationen

- SwiftData ist die dauerhafte Quelle für strukturierte App-Daten. Bilder liegen
  als app-eigene Dateien unter Application Support; SwiftData speichert nur
  relative Schlüssel und Metadaten.
- Aktuell ist CloudKit absichtlich nicht aktiv (`cloudKitDatabase: .none`). Es
  darf nicht beiläufig eingeschaltet werden: Dafür sind ein geeignetes Apple
  Developer Team, Entitlements, Container, Migrationstests und eine separate
  Synchronisationsstrategie für Bilddateien erforderlich.
- Das Löschen der App entfernt derzeit lokale SwiftData-Daten und lokale Bilder.
  Eine Neuinstallation über Xcode soll den App-Container dagegen bewahren.
- Persistierte Enum-Rohwerte, Modellfelder und Beziehungen stabil halten.
  Schemaänderungen über eine neue versionierte SwiftData-Schema-Version und
  einen expliziten Migrationsschritt durchführen.
- Keine destruktive Migration und kein Löschen des App-Containers als bequeme
  Fehlerbehebung. Bestehende Nutzerdaten haben Vorrang.
- `providerMetadata` enthält bereits codierte Zusammenfassungen früherer
  Dreifachanalysen und aktueller Einzelaufrufe. Das Format nur
  rückwärtskompatibel weiterentwickeln.

## Architektur und Implementierung

- Die bestehende, feature-orientierte Struktur `App`, `Domain`, `Features`,
  `Infrastructure` und `Shared` beibehalten.
- SwiftUI-Views rendern Zustand und leiten Aktionen weiter. Berechnungen,
  Aggregation, Validierung und Statusübergänge gehören in kleine, möglichst
  deterministische Domain-Services oder Builder.
- Netzwerk-, Datei- und Keychain-Zugriffe hinter Protokollen kapseln und
  Abhängigkeiten injizieren, damit sie testbar bleiben.
- Swift Concurrency (`async`/`await`) verwenden. UI-Mutationen laufen auf dem
  Main Actor; Netzwerk- und Dateiarbeit darf die Oberfläche nicht blockieren.
- Analyse-Revisionen sind unveränderlich-in-practice: Korrekturen und erneute
  Analysen erzeugen neue Revisionen statt alte Ergebnisse zu überschreiben.
- Datumsgruppierung immer mit einem expliziten Kalender vornehmen und keine
  festen 86.400-Sekunden-Tage annehmen.
- Das Projekt verwendet Xcodes file-system-synchronised groups. Neue
  Swift-Dateien in den vorhandenen Target-Ordnern benötigen normalerweise keine
  manuelle Änderung an `project.pbxproj`.
- Die bestehende Mindestversion iOS 26.2 nicht ohne ausdrücklichen Grund ändern.

## Tests und Qualitätskontrolle

- Routing, Präsentation und kritische Nutzerabläufe mit UI-Tests abdecken.
- Für Build-, Test-, Simulator- und Geräteabläufe die Ziele in
  `apps/ios/Makefile` verwenden. `make help` listet die verfügbaren Befehle auf;
  fokussierte Tests laufen über `make test TEST_TARGET=...` beziehungsweise vom
  Root über `make ios-test TEST_TARGET=...`.
- Verfügbare Simulatoren bei Bedarf mit `make simulators` prüfen und keine
  Simulator-UUID dauerhaft voraussetzen. Einen abweichenden Simulator über
  `SIMULATOR_NAME` beziehungsweise `SIMULATOR_OS` auswählen.
- UI-Texte auf kleinen Displays, mit Dynamic Type und VoiceOver-tauglichen
  Labels prüfen. Kamera-, Netzwerk-, Offline-, Abbruch- und Fehlerpfade nicht
  nur den Happy Path berücksichtigen.

## Installation auf das iPhone des Entwicklers

- „Auf mein Handy spielen“ oder „auf das iPhone pushen“ bedeutet: bauen,
  installieren und möglichst starten. Es bedeutet nicht automatisch einen
  Git-Push.
- Nur installieren, wenn der Nutzer dies für die aktuelle Änderung verlangt.
  Zuvor committen, falls ebenfalls verlangt, und anschließend
  `make deploy-device` in `apps/ios` oder `make ios-deploy-device` im Root
  verwenden. Für einzelne Schritte stehen `build-device`, `install-device` und
  `launch-device` beziehungsweise ihre `ios-*`-Varianten bereit.
- Das Makefile adressiert standardmäßig `Clemens-iPhone2` über den Gerätenamen.
  Bei Bedarf zuerst `make devices` ausführen und ein anderes Gerät über
  `DEVICE=...` wählen.
- Geräte-Builds verwenden ausschließlich vorhandene lokale Signierungsdaten.
  Niemals `-allowProvisioningUpdates` für den normalen Build oder die
  Installation verwenden. Ist das Personal-Team-Profil abgelaufen oder fehlt
  es, den Nutzer darüber informieren und die Erneuerung bewusst in Xcode
  durchführen lassen.
- Die App niemals vorher löschen, da dadurch lokale Mahlzeiten und Bilder
  verloren gehen können. Eine normale Xcode-/devicectl-Installation aktualisiert
  die App und erhält den Container.
- Nach Installation das tatsächliche Ergebnis für Build, Installation und Start
  jeweils getrennt und wahrheitsgemäß angeben.
