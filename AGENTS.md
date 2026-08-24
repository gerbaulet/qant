# Arbeitsanweisungen für Qant

## Geltungsbereich und Priorität

Diese Datei gilt für das gesamte Repository. Direkte Anweisungen des Nutzers im
aktuellen Auftrag haben immer Vorrang. Unterverzeichnisse dürfen ergänzende
`AGENTS.md`-Dateien enthalten; deren Regeln gelten zusätzlich in ihrem Bereich.

`ARCHITECTURE.md` beschreibt die ursprüngliche Architektur und Roadmap. Die
Roadmap ist inzwischen umgesetzt. Vor neuen Arbeiten immer den tatsächlichen
Code, die Tests und die Git-Historie prüfen und keine frühere Phase ungefragt
erneut implementieren.

## Produktgrundsätze

- Der sichtbare App-Name lautet **Qant**. Interne Target-, Scheme- und
  Bundle-Namen nur ändern, wenn dies ausdrücklich erforderlich ist.
- Die Bedienoberfläche ist deutsch. Code, Typnamen, Testnamen und technische
  Kommentare bleiben auf Englisch.
- Die App soll für nicht technische Nutzer verständlich sein. Unnötige
  Bestätigungen und Fachbegriffe vermeiden; relevante Unsicherheit transparent
  erklären.
- Ernährungsschätzungen sind Schätzwerte, keine medizinische Beratung.
- Die App ist local-first und datensparsam. Keine Analytics, Werbung, Accounts,
  HealthKit-, Standort- oder andere zusätzliche Datenerfassung ohne
  ausdrücklichen Auftrag.
- Niemals API-Schlüssel, Bildinhalte, Mahlzeitenkommentare oder andere private
  Nutzerdaten protokollieren oder in das Repository aufnehmen.

## Aktuelle verbindliche Produktlogik

### KI-Analyse und Rückfragen

- Eine initiale Mahlzeitenanalyse führt genau drei unabhängige Anfragen mit dem
  ausgewählten OpenRouter-Modell aus.
- Die drei gültigen Ergebnisse werden gemittelt. Der Analyseverlauf zeigt für
  jeden Lauf Modellkennung, falls vorhanden Provider, und kcal-Ergebnis.
- Eine Rückfrage wegen abweichender Schätzungen wird ausschließlich durch die
  Energieangaben ausgelöst. Makros, Gewicht oder Komponenten dürfen diese
  Rückfrage nicht auslösen.
- Die Abweichungsfrage wird nur gestellt, wenn **beide** Bedingungen gelten:
  `max(kcal) - min(kcal) >= 10` und
  `(max(kcal) - min(kcal)) / mean(kcal) >= 0.35`.
- Liefern mindestens zwei der drei Läufe eine inhaltliche Rückfrage, wird die
  erste vorhandene Frage verwendet. Wortgleichheit ist nicht erforderlich.
- Erfolgt eine gültige Schätzung ohne vorherige Rückfrage, wird sie automatisch
  bestätigt. Nur wenn es zuvor eine Rückfrage gab, bleibt das anschließende
  Ergebnis zur manuellen Bestätigung offen.
- Die bestehende finale Rückfrage und Antwort werden im Analyseverlauf über die
  vorhandenen Felder der Revision dargestellt. Keine neue Persistenz nur für
  rohe Einzel-Rückfragen der drei Modellläufe einführen.
- Änderungen an Schwellenwerten, Mittelwertbildung, Statusübergängen oder
  Rückfrageauswahl brauchen gezielte Unit-Tests, insbesondere für Grenzwerte.

### Aufnahme und Schnellzugriff

- Der Action-Button beziehungsweise App Intent öffnet unmittelbar die Kamera,
  auch wenn Qant bereits im Vordergrund ist.
- Vor dem Sprung zur Kamera müssen präsentierte Mahlzeitendetails, Review-Sheets,
  Dialoge und andere Modals zuverlässig geschlossen werden.
- In der Aufnahmeansicht stehen „Zeitpunkt“ und „Art der Mahlzeit“ unten. Sie
  sind standardmäßig eingeklappt und können bei Bedarf aufgeklappt werden.
- Mahlzeiten können gelöscht werden. Dabei auch zugehörige Analysedaten und von
  der App verwaltete Bilddateien konsistent entfernen.

### Heute, Mahlzeiten und Analyseverlauf

- Für Tag, Woche und Monat steht die kcal-Summe rechts in der jeweiligen
  Abschnittsüberschrift. Vorläufige Summen mit `~` markieren; ohne Energiewert
  `— kcal` anzeigen.
- Der Analyseverlauf bewahrt Revisionen nachvollziehbar auf und zeigt die drei
  initialen Modellläufe aufklappbar an.

### OpenRouter-Einstellungen

- Die Modellauswahl ist ein verständliches Menü beziehungsweise Dropdown. Die
  App lädt geeignete Modelle über die OpenRouter-Model-API und bietet zusätzlich
  eine manuelle Modellkennung als fortgeschrittene Option an.
- Nur Modelle anbieten, die die für Qant erforderlichen Bild- und strukturierten
  Ausgaben unterstützen. Die Liste wird nach der von OpenRouter gelieferten
  Popularitätsinformation sortiert; diese Herkunft in der UI verständlich
  machen.
- Den Nutzer darauf hinweisen, dass die initiale Dreifachanalyse ungefähr die
  dreifachen Modellkosten erzeugt.
- Der OpenRouter-Schlüssel gehört ausschließlich in die Keychain. Die gewählte
  Modellkennung darf in UserDefaults gespeichert werden.

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
- `providerMetadata` enthält bereits die codierten Zusammenfassungen der drei
  initialen Läufe. Das Format nur rückwärtskompatibel weiterentwickeln.

## Architektur und Implementierung

- Die bestehende, feature-orientierte Struktur beibehalten:
  `App`, `Domain`, `Features`, `Infrastructure` und `Shared`.
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
- Das Projekt verwendet Xcodes file-system-synchronised groups. Neue Swift-Dateien
  in den vorhandenen Target-Ordnern benötigen normalerweise keine manuelle
  Änderung an `project.pbxproj`.
- Die bestehende Mindestversion iOS 26.2 nicht ohne ausdrücklichen Grund ändern.

## Tests und Qualitätskontrolle

- Für jede Verhaltensänderung zuerst die nächstgelegenen vorhandenen Tests
  erweitern. Neue reine Geschäftslogik mit Unit-Tests absichern; Routing,
  Präsentation und kritische Nutzerabläufe mit UI-Tests abdecken.
- Mindestens die fokussierten Tests der Änderung ausführen. Vor einem Commit mit
  breiter Wirkung zusätzlich die vollständige Unit-Test-Suite ausführen.
- Relevante Befehle verwenden das Projekt `quantified_self.xcodeproj` und das
  Scheme `quantified_self`. Verfügbare Simulatoren immer aktuell mit `simctl`
  ermitteln; keine Simulator-UUID dauerhaft voraussetzen.
- Einen erfolgreichen Build oder Test nur melden, wenn `xcodebuild` tatsächlich
  mit `BUILD SUCCEEDED` beziehungsweise `TEST SUCCEEDED` abgeschlossen wurde.
- UI-Texte auf kleinen Displays, mit Dynamic Type und VoiceOver-tauglichen
  Labels prüfen. Kamera-, Netzwerk-, Offline-, Abbruch- und Fehlerpfade nicht
  nur den Happy Path berücksichtigen.

## Git- und Commit-Regeln

- Vor Änderungen `git status` prüfen. Bereits vorhandene Änderungen gehören dem
  Nutzer; nicht überschreiben, zurücksetzen oder ungefragt in eigene Commits
  aufnehmen.
- Standard für abgeschlossene Implementierungsarbeit in diesem Projekt ist ein
  kleiner, fokussierter Commit pro fachlichem Punkt beziehungsweise Iteration.
- Gibt der Nutzer mehrere Punkte vor, jeden Punkt vollständig umsetzen, testen
  und separat committen, bevor der nächste Punkt begonnen wird. Keine
  Sammelcommits für unabhängige Änderungen.
- Vom Nutzer oder von Xcode erzeugte Änderungen nur dann separat committen, wenn
  der Nutzer dies ausdrücklich verlangt.
- Entwürfe und Dateien zur Review nicht committen. Eine ausdrückliche Anweisung
  wie „noch nicht committen“ hat Vorrang.
- Keine Remote-Pushes, Branch-Rewrites, Resets oder sonstigen destruktiven
  Git-Aktionen ohne ausdrücklichen Auftrag.
- Commit-Nachrichten kurz, auf Englisch und im Imperativ formulieren, passend zur
  bestehenden Historie.

## Installation auf das iPhone des Entwicklers

- „Auf mein Handy spielen“ oder „auf das iPhone pushen“ bedeutet in diesem
  Projekt: bauen, installieren und möglichst starten. Es bedeutet nicht
  automatisch einen Git-Push.
- Nur installieren, wenn der Nutzer dies für die aktuelle Änderung verlangt.
  Zuvor committen, falls ebenfalls verlangt, und einen signierten Debug-Build
  für `generic/platform=iOS` mit dem ausgewählten Personal Team erzeugen.
- Das aktuell angeschlossene Gerät über `xcrun devicectl list devices` ermitteln;
  nicht auf eine dauerhaft gleichbleibende Geräte-ID vertrauen. Das bekannte
  Gerät heißt üblicherweise `Clemens-iPhone2`.
- Die App mit `xcrun devicectl device install app` installieren und über die
  Bundle-ID `de.clemensgerbaulet.quantified-self` starten.
- Die App niemals vorher löschen, da dadurch lokale Mahlzeiten und Bilder
  verloren gehen können. Eine normale Xcode-/devicectl-Installation aktualisiert
  die App und erhält den Container.
- Nach Installation das tatsächliche Ergebnis melden: Commit, Build,
  Installation und Start jeweils getrennt und wahrheitsgemäß angeben.

## Abschluss eines Auftrags

Ein Punkt ist erst fertig, wenn Implementierung, passende Tests und eine Prüfung
des Git-Diffs abgeschlossen sind. Bei mehreren verlangten Commits muss jeder
Commit genau seinen Punkt enthalten. In der Abschlussmeldung kurz nennen, was
geändert und getestet wurde, ob ein Commit erstellt wurde und ob die App auf dem
iPhone installiert wurde.
