# Quantified Self Nutrition — Architecture

## Current repository

The repository started as the Xcode SwiftData application template created with
Xcode 26.3. It contained one `Item(timestamp:)` entity, a generated split-view
list, and placeholder unit/UI tests. There were no capabilities, packages,
privacy usage descriptions, or app-specific domain concepts yet.

The project uses Xcode's file-system-synchronised groups. New Swift files placed
under `quantified_self/` or `quantified_selfTests/` therefore belong to their
respective targets without hand-editing `project.pbxproj`.

## Architectural shape

The app will use a small, feature-oriented architecture:

```text
quantified_self/
  App/                 app composition and dependency wiring
  Domain/
    Models/            SwiftData entities and small value types
    Services/          deterministic domain calculations
  Features/
    Today/
    DinnerSuggestions/
    Capture/
    Meals/
    Trends/
    Settings/
  Infrastructure/
    Analysis/          OpenRouter implementation and DTOs
    ImageStorage/      image files and thumbnails
    Persistence/       repositories and migration support
    Security/          Keychain-backed secret storage
    Notifications/
  Shared/              reusable presentation components and formatters
```

Folders are added only when their first concrete type is needed. This keeps the
codebase navigable without creating empty architecture.

### State management

SwiftData is the durable source of truth. Feature-scoped `@Observable`
controllers will own transient UI state and orchestrate use cases. Views will
render state and send user actions to those controllers; calculations and state
transitions do not live in `View.body`.

Dependencies are protocol-typed and injected at the feature boundary. The app
will use Swift structured concurrency (`async`/`await`) for image processing and
analysis. An analysis coordinator will own one task per meal so SwiftUI view
lifecycle callbacks cannot accidentally duplicate requests. UI-facing mutation
runs on the main actor; file and network work does not.

## Persistence model

All persisted entities receive an application-generated UUID and creation and/or
modification dates. UUIDs deliberately do not use SwiftData's `.unique`
constraint because CloudKit-backed stores do not support uniqueness constraints.
The application will enforce identity rules at repository boundaries.
The initial models are registered as `NutritionSchemaV1` and the container uses
an explicit `NutritionMigrationPlan`, so the first later schema change is made by
adding V2 and a migration stage rather than silently changing the live schema.

### `Meal`

- Actual timestamp as `Date`, never a formatted string.
- Optional user comment and editable classification.
- Capture and analysis state stored independently.
- Ordered to-many relationships to `MealImage` and `MealAnalysisRevision`.
- `activeRevisionID` selects the provisional/confirmed result without deleting
  older revisions.
- Clarification count provides a simple, enforceable loop limit later.

### `MealImage`

- Stores relative file keys and dimensions, not photo bytes.
- A sort index preserves the user's image order.
- Separate review-image and thumbnail keys avoid decoding large images in lists.
- Cascade deletion from a meal removes metadata; the repository will coordinate
  deletion of the corresponding files.

### `MealAnalysisRevision`

- Immutable-in-practice record of one complete AI result.
- Stores model, provider/routing metadata when available, request date, and
  prompt/schema version for reproducibility.
- Records confidence, uncertainty, correction or clarification context, and its
  own status.
- Owns meal-level nutrients and food components. A new correction creates a new
  revision; it never overwrites the prior one.

### `FoodComponent` and `NutrientValue`

Meal totals and component estimates are separate relationships. Nutrients use a
typed/flexible bridge: known identifiers and units are Swift enums at API
boundaries, while their persisted values are strings. This catches ordinary
mistakes in code but allows a newer model response to retain an unfamiliar
nutrient without a store migration. Each value also carries confidence and
provenance (`label`, `calculatedFromLabel`, `visualEstimate`, user text, or
mixed).

### `NutritionGoalPeriod`

One effective-dated entity represents calorie and macro targets. Its half-open
interval is `[validFrom, validUntil)`, so an exact boundary belongs to the new
goal. A weekly target is the sum of the goal applicable at the start of each
local calendar day, correctly supporting mid-week changes. One shared model
avoids duplicating history logic for calories, protein, carbohydrates, fat, and
fiber.

Goal effective dates are stored as absolute `Date` values, normalised to the
selected local day's start when created. Day and week grouping always uses an
explicit `Calendar` supplied by the feature (normally `.autoupdatingCurrent`).
Consequently, the UI follows the user's current locale/time zone during travel,
including DST day lengths, rather than assuming that every day is 86,400
seconds. A future export can additionally record creation-time zone metadata if
fixed home-zone reporting becomes desirable.

### Later entities

`AppSettings` and optionally persisted `WeeklySummary` will be introduced with
their features. API keys are never entities: only the Keychain stores secrets.
Simple preferences such as the selected model may use app storage; settings that
need history or CloudKit synchronisation will use SwiftData.

### Dinner suggestions

The version 2 schema adds `DinnerSuggestionBatch`, `DinnerSuggestion`,
`DinnerSuggestionIngredient`, and `DinnerSuggestionNutrient`. A batch preserves
the date, model/provider, portion count, preference snapshot, and nutrient
budget used for one generation. It owns exactly the three returned dinner
suggestions. Suggestions own their ingredients and per-serving nutrient values
and may be favourited or deleted independently. The V1-to-V2 change is additive
and uses an explicit lightweight migration so existing meals, goals, revisions,
and image references remain untouched.

Simple reusable dinner preferences live locally in UserDefaults: dietary style,
allergies/intolerances, excluded ingredients, preferred cuisines, maximum
preparation time, kitchen equipment, and available ingredients. Available
ingredients stay prefilled after generation and are never automatically
decremented. These values are sent externally only when the user explicitly
requests dinner suggestions.

`DinnerSuggestionProviding` is a separate AI boundary from meal-photo analysis.
One user action makes one structured OpenRouter request and returns exactly
three generic, brand-free alternatives. Each alternative contains a name,
ingredients scaled to the requested total portion count, a short fit rationale,
and energy, protein, carbohydrates, fat, and fibre per serving. There is no
three-run consensus for suggestions.

A deterministic domain builder derives the remaining daily budget from the same
confirmed and provisional revisions used by Today. It prioritises energy within
10 percent, then protein and fibre deficits, followed by carbohydrates and fat.
An energy overshoot may rank ahead when it improves the weighted open macro gap
by at least 20 percent. If the energy budget is already exhausted, the request
explicitly asks for light alternatives and the UI explains that no calorie room
remains. Missing goals are never replaced with invented defaults.

Generating a suggestion never changes meal totals. Saved suggestions retain the
budget snapshot on which they were generated; only a separately captured and
analysed meal contributes to Today and trends.

## Image storage

`ImageStorageProviding` will expose save, load, and delete operations using
opaque relative keys. Its actor-based implementation will write app-owned files
under Application Support in per-meal directories. On import it will:

1. apply orientation and downsample rather than decode full-resolution pixels,
2. create a review/analysis image large enough for food and label inspection,
3. create a small list thumbnail,
4. use a modern compressed format supported by the captured content,
5. atomically write files before committing their metadata.

SwiftData therefore remains fast and CloudKit records stay small. The capture
transaction persists the meal and file references before analysis starts. If
analysis fails or the app is offline, the meal and files remain available.
File cleanup is an explicit repository operation, because SwiftData deletion
rules cannot delete external files.

## AI boundary

The feature layer depends on `NutritionAnalysisProviding`, not OpenRouter:

```swift
protocol NutritionAnalysisProviding: Sendable {
    func analyze(_ request: NutritionAnalysisRequest) async throws
        -> NutritionAnalysisResult
}
```

The request contains all prepared images, the original comment, and optional
prior result plus correction/clarification context. The result is a strongly
typed `Codable` value. `OpenRouterNutritionAnalysisService` will be an actor that
handles request construction, JSON Schema structured output, authentication,
timeouts, and provider errors. A separate validator rejects non-finite,
negative, malformed, or physically implausible values before mapping the result
into a new persisted revision.

The OpenRouter key comes from a `SecretStore` Keychain implementation and is
never logged. This protocol boundary also allows a later backend proxy to replace
the direct OpenRouter client without changing capture or review features.

## Required capabilities and privacy declarations

Capabilities will be added only with the corresponding milestone:

- Camera usage description (`NSCameraUsageDescription`).
- Photo-library read access via `PhotosPicker`; add-photo-library permission is
  not needed unless the app later writes to the library.
- Network access uses normal HTTPS and needs no special entitlement.
- Local notification permission for the weekly reminder.
- App Intents and a WidgetKit extension for quick capture/today status.
- iCloud + CloudKit containers only after the local model and migrations are
  stable.

No HealthKit, fitness, location, analytics, advertising, or background networking
capabilities belong in this phase.

## Decisions to make just before their milestones

- Maximum retained image dimension/quality after testing real nutrition labels.
- Default OpenRouter model and whether it reliably supports the chosen JSON
  Schema dialect and multiple images.
- Whether unconfirmed estimates count provisionally. Proposed policy: include
  them in totals with a clearly marked provisional style; exclude failed,
  pending, and clarification-only meals with no valid revision.
- Maximum clarification cycles. Proposed MVP limit: two, always with “best
  estimate” available.
- Home-time-zone versus current-time-zone historical reports. The initial policy
  is current calendar/time zone, as described above.
- CloudKit container identifier and sync opt-in behaviour.

## Roadmap

1. **Foundation:** domain persistence schema, effective-dated goals, model-store
   smoke test, and migration notes.
2. **Today shell:** four-tab German app shell and sample-data dashboard.
3. **Meal capture:** draft/save flow, timestamps, comments, classification, and
   immediate local persistence.
4. **Images:** camera, multi-select photo import, file storage, thumbnails, and
   failure cleanup.
5. **AI configuration:** Keychain secret, configurable model, test request, and
   privacy copy.
6. **Structured analysis:** OpenRouter DTOs, schema, validation, orchestration,
   retry, offline pending state, and request tests.
7. **Review:** provisional totals, confidence/uncertainty, confirmation, and food
   components/micronutrients.
8. **Clarifications and corrections:** bounded questions, best-estimate escape,
   re-analysis, and immutable revision history.
9. **Aggregation:** daily/weekly nutrient totals, goal-aware deterministic hints,
   and completeness policy.
10. **Meal history:** day/week/month grouping and readable details.
11. **Trends:** Charts, tracked-day-aware ranges, partial-month comparisons, and
    deterministic trend text.
12. **Weekly summary:** local calculations and Sunday 20:00 local notification.
13. **Quick capture:** App Intent/Shortcut first, then a minimal widget if useful.
14. **CloudKit hardening:** compatibility audit, migration tests, sync, and backup.
15. **Release readiness:** UI tests, accessibility, German string catalog with
    English localisation, privacy review, export planning, and failure testing.

Each milestone should remain independently buildable and tested. Fitness,
HealthKit, body metrics, barcodes, accounts, and a backend stay out of scope.
