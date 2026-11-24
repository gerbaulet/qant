# Arbeitsanweisungen für Quant Server

## Geltungsbereich

Diese Datei ergänzt die Regeln im Repository-Root für `apps/server`.

## Architektur und Datenschutz

- Der Server bleibt ein kleiner, zweckgebundener OpenRouter-Relay und kein
  allgemeiner HTTP-Proxy. Neue Endpunkte benötigen einen konkreten
  Quant-Anwendungsfall.
- Die bestehende Go-Struktur unter `cmd/quant-server` und `internal/server`
  beibehalten. Standardbibliothek bevorzugen und neue Abhängigkeiten nur mit
  erkennbarem Nutzen einführen.
- OpenRouter-Schlüssel, Anfragekörper, Modelle, Bilder, Mahlzeitentexte und
  Tailscale-Identitäten niemals protokollieren. Fehlerausgaben müssen ebenfalls
  frei von diesen Daten bleiben.
- Der Container bleibt bei Verwendung von Tailscale Serve ausschließlich an
  Host-Loopback gebunden. Tailscale Funnel nicht verwenden.
- Authentifizierungs-, Idempotenz-, Größen-, Parallelitäts- und TTL-Grenzen nicht
  abschwächen, ohne den Sicherheits- und Ausfallpfad gezielt zu testen.
- Persistierte Jobdateien enthalten nur notwendige gehashte Besitzmetadaten,
  Status und Ergebnis. Bestätigte oder abgelaufene Ergebnisse konsistent
  entfernen.

## Implementierung und Tests

- Nebenläufige Job- und Dateizugriffe race-sicher halten. Request-Limits vor
  teuren Decodes oder Upstream-Aufrufen durchsetzen.
- Für Verhaltensänderungen die Tests in `internal/server` erweitern und
  `make test` ausführen. Zusätzlich bei Container- oder Konfigurationsänderungen
  `make docker-build` und `make config` ausführen.
- Deployment-Skripte müssen von `apps/server` als Quellwurzel ausgehen und ohne
  Annahmen über den aktuellen Aufrufpfad funktionieren.
- Einen Server-Deploy nur auf ausdrücklichen Auftrag ausführen. Dabei vorhandene
  Ziele im Makefile verwenden und das tatsächliche Ergebnis wahrheitsgemäß
  melden.
