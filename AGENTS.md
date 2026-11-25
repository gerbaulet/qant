# Arbeitsanweisungen für Quant

## Geltungsbereich und Priorität

Diese Datei gilt für das gesamte Monorepo. Direkte Anweisungen des Nutzers im
aktuellen Auftrag haben immer Vorrang. Die Unterverzeichnisse `apps/ios` und
`apps/server` enthalten ergänzende `AGENTS.md`-Dateien; deren Regeln gelten
zusätzlich in ihrem jeweiligen Bereich.

`apps/ios/ARCHITECTURE.md` beschreibt die ursprüngliche iOS-Architektur und
Roadmap. Die Roadmap ist inzwischen umgesetzt. Vor neuen Arbeiten immer den
tatsächlichen Code, die Tests und die Git-Historie prüfen und keine frühere
Phase ungefragt erneut implementieren.

## Repository-Aufbau

- `apps/ios` enthält das Xcode-Projekt, die iOS-App, das Widget und deren Tests.
- `apps/server` enthält den Go-Server, Container-Konfiguration und
  Deployment-Skripte.
- Beide Anwendungen bleiben in ihrem Unterordner eigenständig baubar. Das
  Root-`Makefile` delegiert über `ios-*` beziehungsweise `server-*` an die
  anwendungsspezifischen Makefiles.
- Änderungen an gemeinsam verwendeten API-Verträgen auf beiden Seiten
  nachvollziehen und zusammen testen. Keine Quellcodedateien beiläufig zwischen
  den Anwendungen teilen.

## Produktgrundsätze

- Der sichtbare App-Name lautet **Quant**. Interne Target-, Scheme- und
  Bundle-Namen nur ändern, wenn dies ausdrücklich erforderlich ist.
- Die Bedienoberfläche ist deutsch. Code, Typnamen, Testnamen und technische
  Kommentare bleiben auf Englisch.
- Die App soll für nicht technische Nutzer verständlich sein. Unnötige
  Bestätigungen und Fachbegriffe vermeiden; relevante Unsicherheit transparent
  erklären.
- Ernährungsschätzungen sind Schätzwerte, keine medizinische Beratung.
- Die iOS-App ist local-first und datensparsam. Keine Analytics, Werbung,
  Accounts, HealthKit-, Standort- oder andere zusätzliche Datenerfassung ohne
  ausdrücklichen Auftrag.
- Niemals API-Schlüssel, Bildinhalte, Mahlzeitenkommentare, Anfrageinhalte oder
  andere private Nutzerdaten protokollieren oder in das Repository aufnehmen.

## Verbindliche systemweite Analyse-Logik

- Eine Mahlzeitenanalyse führt standardmäßig genau eine Anfrage mit dem
  ausgewählten OpenRouter-Modell aus. Nur eine unlesbare, technisch
  fehlgeschlagene oder lokal als widersprüchlich erkannte Antwort darf genau
  einen weiteren Korrekturversuch auslösen.
- Bei einer initialen Analyse mit Bild werden zwei weitere unabhängige
  Schätzungen parallel angefordert, sofern weder ein Nährwertetikett erkannt
  noch eine belastbare Maßangabe wie Gramm oder Milliliter genannt wurde und
  keine Rückfrage offen ist. Modellkonfidenz und vom Modell angegebene
  Nährwertherkunft beeinflussen diese Entscheidung nicht. Aus drei gültigen
  Schätzungen wird das vollständige Ergebnis mit dem mittleren kcal-Wert
  übernommen; bei einer ungültigen Zusatzschätzung bleibt das erste gültige
  Ergebnis maßgeblich.
- Vor der Anfrage liest die iOS-App Verpackungstext lokal mit Vision-OCR. Der
  erkannte Text unterstützt das Modell zusätzlich zu Bildern und
  Nutzerangaben.
- Das strukturierte Ergebnis enthält pro Bestandteil Gewicht sowie Energie,
  Protein, Kohlenhydrate, Fett und Ballaststoffe. Bei Etikettwerten pro 100 g
  werden diese deterministisch auf die gegessene Menge skaliert und die
  Bestandteile zu Gesamtwerten summiert.
- Der Analyseverlauf zeigt jeden tatsächlichen Aufruf mit Modellkennung, falls
  vorhanden Provider, kcal-Ergebnis und konkretem Validierungsfehler.
- Erfolgt eine gültige Schätzung ohne vorherige Rückfrage, wird sie automatisch
  bestätigt. Nur wenn es zuvor eine Rückfrage gab, bleibt das anschließende
  Ergebnis zur manuellen Bestätigung offen.
- Die bestehende finale Rückfrage und Antwort werden über die vorhandenen
  Felder der Revision dargestellt. Keine neue Persistenz nur für rohe
  Rückfragen einzelner Modellaufrufe einführen.
- Änderungen an Plausibilitätsgrenzen, Berechnung, Statusübergängen oder
  Rückfrageauswahl brauchen gezielte Unit-Tests, insbesondere für Grenzwerte.

## Gemeinsamer Datenschutz- und API-Vertrag

- Der OpenRouter-Schlüssel liegt auf dem iPhone ausschließlich in der Keychain.
  Der Server darf ihn nur für die Laufzeit des zugehörigen Jobs im
  Prozessspeicher halten und niemals persistieren oder protokollieren.
- Bilder, Mahlzeitentexte und vollständige Anfrageinhalte dürfen auf dem Server
  nicht dauerhaft gespeichert oder protokolliert werden. Persistierte Jobdaten
  enthalten nur notwendige Besitzmetadaten, Status und das Ergebnis und werden
  entsprechend der Aufbewahrungsregeln gelöscht.
- Änderungen an Endpunkten, DTOs oder Validierung zwischen iOS-App und Server
  müssen rückwärtskompatibel sein oder in beiden Anwendungen gemeinsam
  migriert werden.

## Tests und Qualitätskontrolle

- Für jede Verhaltensänderung zuerst die nächstgelegenen vorhandenen Tests
  erweitern. Neue reine Geschäftslogik mit Unit-Tests absichern; kritische
  Nutzer- und Serverabläufe einschließlich Fehlerpfaden berücksichtigen.
- Mindestens die fokussierten Tests der Änderung ausführen. Vor einem Commit mit
  breiter Wirkung zusätzlich die vollständige passende Unit-Test-Suite
  ausführen.
- Build- und Testziele über die Makefiles verwenden. Vom Root aus stehen sie
  als `make ios-<target>` und `make server-<target>` zur Verfügung; innerhalb
  einer Anwendung weiterhin als `make <target>`.
- Einen erfolgreichen Build oder Test nur melden, wenn das jeweilige Werkzeug
  tatsächlich erfolgreich abgeschlossen wurde. Für Xcode sind dafür
  insbesondere `BUILD SUCCEEDED` beziehungsweise `TEST SUCCEEDED` maßgeblich.

## Git- und Commit-Regeln

- In diesem Repository ausschließlich normales Git über die `git`-CLI
  verwenden. GitButler, die `but`-CLI und den GitButler-Skill nicht verwenden.
- Vor Änderungen `git status` prüfen. Bereits vorhandene Änderungen gehören
  dem Nutzer; nicht überschreiben, zurücksetzen oder ungefragt in eigene
  Commits aufnehmen.
- Mehrere unabhängige Codex-Chats dürfen parallel arbeiten. Der primäre
  Checkout auf `main` dient dabei ausschließlich als sauberer
  Integrations-Checkout; Codeänderungen niemals direkt dort vornehmen.
- Jeder Chat mit einem Änderungsauftrag erstellt vor der ersten Dateiänderung
  mit `scripts/codex-worktree.sh create <task-slug>` einen eigenen Worktree und
  arbeitet anschließend ausschließlich im ausgegebenen Pfad. Keine fremden
  Worktrees, Branches oder Sperren verändern oder entfernen.
- Ein fachlicher Arbeitspunkt entspricht einem Worktree und einem fokussierten
  Commit. Für einen weiteren unabhängigen Commit den ersten Punkt vollständig
  integrieren und aufräumen und danach einen neuen Worktree erstellen.
- Vor dem Commit die passenden Tests und den vollständigen Diff prüfen. Danach
  im Worktree `scripts/codex-worktree.sh prepare` ausführen, die betroffenen
  Tests auf dem rebasierten Stand erneut ausführen und schließlich
  `scripts/codex-worktree.sh finish` aufrufen.
- `finish` serialisiert parallele Integrationen, übernimmt den Commit per
  Fast-Forward in den lokalen Branch `main`, versucht `main` zum konfigurierten
  Upstream zu pushen und entfernt danach den eigenen Worktree sowie seinen
  temporären Branch. Meldet es einen vorübergehenden Konflikt, weil `main`
  zwischenzeitlich fortgeschritten oder die Sperre belegt ist, `prepare`, Tests
  und `finish` selbstständig wiederholen.
- Der Push durch `finish` ist der Standard, damit abgeschlossene Arbeit auch
  remote gesichert wird. Fehlt ein Remote oder schlägt der Push fehl, bleibt der
  Commit lokal auf `main` erhalten; den konkreten Push-Status in der
  Abschlussmeldung nennen. Verlangt der Nutzer ausdrücklich keinen Push,
  `scripts/codex-worktree.sh finish --no-push` verwenden.
- Rebase-Konflikte selbst auflösen, wenn die fachlich richtige Auflösung aus
  Auftrag, Code und Tests eindeutig hervorgeht. Andernfalls `main` unverändert
  lassen, den Worktree behalten und den konkreten Konflikt melden.
- Niemals in einem detached `HEAD` committen. Für Worktrees ausschließlich das
  Skript verwenden und weder `git worktree remove --force`,
  `git worktree prune` noch `git branch -D` ausführen.
- Standard für abgeschlossene Implementierungsarbeit ist ein kleiner,
  fokussierter Commit pro fachlichem Punkt beziehungsweise Iteration.
- Gibt der Nutzer mehrere Punkte vor, jeden Punkt vollständig umsetzen, testen
  und separat committen, bevor der nächste begonnen wird. Keine Sammelcommits
  für unabhängige Änderungen.
- Vom Nutzer oder von Entwicklungswerkzeugen erzeugte Änderungen nur dann
  separat committen, wenn der Nutzer dies ausdrücklich verlangt.
- Entwürfe und Dateien zur Review nicht committen. Eine ausdrückliche Anweisung
  wie „noch nicht committen“ hat Vorrang.
- Außer dem standardmäßigen Push durch `finish` keine Remote-Pushes ausführen.
  Niemals Force-Pushes, Branch-Rewrites, Resets oder sonstige destruktive
  Git-Aktionen ohne ausdrücklichen Auftrag ausführen.
- Commit-Nachrichten kurz, auf Englisch und im Imperativ formulieren, passend
  zur bestehenden Historie.

## Abschluss eines Auftrags

Ein Punkt ist erst fertig, wenn Implementierung, passende Tests und eine
Prüfung des Git-Diffs abgeschlossen sind. Bei mehreren verlangten Commits muss
jeder Commit genau seinen Punkt enthalten. In der Abschlussmeldung kurz nennen,
was geändert und getestet wurde, welcher finale Commit auf `main` erstellt
wurde, ob Worktree und temporärer Branch erfolgreich entfernt wurden und ob
eine Anwendung installiert, gestartet, deployed oder gepusht wurde.
