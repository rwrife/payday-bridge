# Payday Bridge

Offline iPhone payday planner for irregular earners: place upcoming bills against confirmed pay envelopes and see what remains without banking access.

## Why and who
Monthly budgets hide the gap between a bill's due date and the next paycheck. Payday Bridge helps shift workers, freelancers and households with uneven pay dates plan one short horizon at a time. It is a manual planning worksheet, not a bank balance, payment service or financial adviser.

## Intended workflow and use cases
1. Choose one currency and enter a dated opening cash snapshot yourself.
2. Add dated income entries, distinguishing expected from confirmed amounts. Expected income never appears in confirmed coverage.
3. Add one-off or monthly bill occurrences with due dates; an unknown amount stays unknown rather than becoming zero.
4. Assign a bill to a pay envelope. The app flags funding dates after the bill's due date and envelopes whose assigned amounts exceed confirmed funds. A warning does not move or pay a bill.
5. Compare the original plan with a separate what-if draft. Confirm changes explicitly; editing a draft cannot alter the saved plan.
6. Mark an occurrence paid or undo the mark; backup the whole worksheet or export a dated CSV snapshot.

Examples: plan rent before a delayed paycheck, reserve a utility bill with an uncertain amount, or compare which confirmed paycheck covers a yearly fee. Totals are user-entered planning estimates, never verified available bank funds.

## MVP
- Single-currency, 90-day worksheet with dated cash snapshot, confirmed/expected income and bills.
- Manual pay-envelope assignment, decimal-safe amounts and explainable coverage warnings.
- Monthly recurrence with explicit month-end clamping and independently editable occurrences.
- Draft what-if comparison with explicit apply/discard; pending/paid/unknown states.
- Local JSON persistence, portable versioned JSON backup with previewed restore, and CSV export.
- Accessible compact iPhone workflow and a `PaydayWorkspaceLayout` composition seam.

## Platform and dual-screen direction
Native Swift (SwiftUI/UIKit) iPhone-only; iOS 26-or-newer SDK. Planned pin: Xcode 26.0.1 (17A400), Swift 6, iOS SDK 26.0.
Set `TARGETED_DEVICE_FAMILY = 1` in every app configuration and generator; verify built `UIDeviceFamily == [1]` on Apple CI. Native iPad support is disabled.
Bundle identifier: `com.infinityball.paydaybridge`; ASC registration returned `CREATED com.infinityball.paydaybridge`.

iPhone Duo is a design target, not a verified device capability. One future display keeps the dated bill timeline visible while the other hosts envelope allocation and a what-if comparison. Today build a standard single-screen iPhone app, preserving selection/drafts across compact layout changes through `PaydayWorkspaceLayout`. No unavailable fold SDK APIs; iPad layouts require explicit opt-in.

## Privacy, storage and accessibility
No accounts, networking, ads, trackers, bank login, or cloud sync. Store Codable JSON in device Application Support using atomic replacement and file protection; no raw account numbers or credentials. User exports contain sensitive financial amounts: show a preview and share only on deliberate action. OS backup/share destinations remain user-controlled; do not describe them as never leaving the phone. Import validates version, currency, identifiers, amounts, dates and file limits before modifying anything, creates a recovery backup and restores transactionally. Confirm destructive replacement; keep current data on parse/write failure.

No camera, contacts, location, microphone, HealthKit, notification or sensor permission is needed. VoiceOver announces uncertainty and coverage reasons, Dynamic Type reflows, color is never the sole warning cue, and all controls have accessible labels and adequate touch targets.

## Non-goals
No Android, native iPad support, cloud/bank sync, payments, borrowing, investment/tax advice, guaranteed solvency, multi-currency conversion, household sharing or automated bill cancellation.
No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity or other cross-platform/hybrid frameworks.
No generic expense tracker, receipt splitting or long-term forecasting. The lazier alternative is a dated spreadsheet; this app earns its existence through due-date-aware assignment and safe what-if comparisons.

## Status and milestones
- M1 (Issue #1): Native SwiftUI iPhone skeleton, shared Xcode scheme, pure-Swift PaydayBridgeKit package, exact toolchain pin on macos-26, iPhone-only enforcement (`TARGETED_DEVICE_FAMILY = 1` and built `UIDeviceFamily == [1]`), zero-network allowlist gate, and native-only dependency gate.
- M2 (Issue #2): Pure-Swift Foundation package implements validated Codable money/civil dates, anchored recurrence, stable paid/amount overrides, exclusive envelope assignments and explainable coverage. App worksheet editing is still unavailable; the app remains a launch-only skeleton. Linux package tests do not establish native iOS build or UI evidence.
- M3–M7: Storage, revision-safe drafts, app editing, accessibility, import/export and release remain upcoming; see PLAN.md.

Domain ceilings are deliberate: 1–90 day civil span (start through start + days, inclusive endpoints), years 1900–9999, amounts below 1,000,000,000 (including aggregate displayed funds), 1,000 bills/incomes each, 10,000 overrides/assignments each, and nonblank bill titles of at most 200 characters. Supported currencies: USD/EUR/GBP/CAD/AUD/CHF/NZD (2 decimal places), JPY (0). No conversion. Monthly keys use bill UUID plus original year-month, independent of clamped day and amount; one-off keys use UUID plus `once`. The optional `AmountOverride` distinguishes inheritance (`nil`), explicit unknown (`.unknown`) and a known value (`.value(Money)`). The existing `OccurrenceOverride(amount: Money? = nil, paid:)` convenience initializer still treats nil as inheritance; use `amountOverride: .unknown` to clear a known amount. JSON stores this distinction in `amountOverride`.

Canonical monthly references remain valid before the current recurrence start. Moving the start later preserves saved override identities, amounts and paid history; visible generation includes months with saved overrides before that start, using the current clamped day anchor. Unsaved months before the start are not generated. All valid assigned occurrences, including off-window one-off and recurring keys, reserve their envelopes regardless of the visible horizon. Unknown reservations propagate to visible unpaid bills sharing the envelope.

Coverage starts on or after the cash snapshot. **Conservative civil-date rule: opening cash includes all cash received on or before `openingDate`.** Only income strictly after that date and through the horizon end contributes to confirmed/expected totals. Assignments to income on or before the snapshot show `snapshotAlreadyIncluded` and cannot fund a separate envelope. Opening cash counts once. **The snapshot already reflects paid bills assigned to opening cash**, so those paid commitments are excluded. Paid occurrences assigned to income after the snapshot still consume that income, including off-window payments and unknown amounts. Expected income is separate and never supplies confirmed coverage. `Coverage` and `CoverageItem` are derived `Sendable` results, not Codable inputs; import a validated worksheet and recompute coverage.

## Development quickstart
- **Linux package tests (pure Swift domain)**: `swift test --package-path Packages/PaydayBridgeKit`
- **Gate checks**: `bash scripts/check_zero_network.sh && bash scripts/check_native_only.sh`
- **Native iOS app build**: macOS with measured Xcode 26.0.1 (17A400) and iOS 26+ SDK:
  `xcodebuild -project PaydayBridge.xcodeproj -scheme PaydayBridge -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`

## Store and distribution contract
`AppStore/description.txt` is pre-release copy; reconcile it with implemented features before release. Generate real `AppStore/icon.png` after the skeleton exists using the requested `hermes-image-gen` model and the exact issue #7 brief; verify opaque square edge-to-edge artwork and Xcode asset wiring. No placeholder icon or silent model substitution.

Issue #7 must implement `.github/workflows/release.yml` by porting the proven rwrife/cook-console publish template: `v*` tag or manual dispatch, macos-26, exact Xcode/iOS 26+ checks, mode-600 ASC key, signed IPA archive/export, TestFlight upload, processing wait and GitHub release. Secrets configured by name: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`; never log values. Registration of the bundle ID does not establish an app record, signing readiness or store approval. Require real run URL, archive metadata and processed build evidence before claiming distribution.

MIT licensed.
