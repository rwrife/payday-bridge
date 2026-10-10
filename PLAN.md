# Payday Bridge implementation plan

## Scope and architecture
Native Swift (SwiftUI/UIKit), iPhone-only. No Android. Native iPad support is disabled. Xcode 26.0.1 (17A400), Swift 6 and iOS 26+ SDK; minimum deployment 26.0. `TARGETED_DEVICE_FAMILY = 1` everywhere and built `UIDeviceFamily == [1]` require native CI evidence.
Bundle identifier `com.infinityball.paydaybridge` is registered in App Store Connect (`CREATED com.infinityball.paydaybridge`). Pins in toolchain.json are planning declarations until measured.

Use a small pure-Swift PaydayBridgeKit package for dates, money, occurrences, envelope coverage and draft comparison; SwiftUI app for presentation; Codable JSON snapshot stored atomically in Application Support. Use Apple Foundation Calendar and Decimal rather than adding dependencies. Persist only what the worksheet needs: currency, cash snapshot, income entries (expected/confirmed), bills, generated occurrences, manual assignments, paid marks and draft revision. Use stable UUIDs; define file-schema version and explicit validation limits. No bank integration or runtime network.

### Planning rules
- Decimal-safe currency precision; reject negative/nonfinite/out-of-range amounts, malformed dates, foreign currency and duplicate IDs. Never use binary floating-point currency arithmetic.
- Dates are local civil dates, not elapsed seconds. Generate at most 90 days of occurrences. Monthly day 29/30/31 clamps to month end without drifting the original recurrence anchor; re-generation preserves occurrence overrides and paid marks. Canonical monthly keys remain valid before an edited start; saved override months remain visible using the current day anchor, while unsaved earlier months are not generated.
- Confirmed funds and expected income are shown separately. Unknown bill amounts prevent a complete coverage conclusion; they never become zero. Optional `AmountOverride` distinguishes inheritance from explicit unknown and known value; the Money convenience initializer retains nil-as-inherit behavior. Derived Coverage/Items are Sendable only, never decoded from imports. Label all totals as entered planning values, never bank-verified funds.
- Opening cash belongs to only one initial envelope; it cannot be counted once per paycheck. Each occurrence has at most one assignment. An income/envelope can cover several occurrences but allocations cannot hide overcommitment. Valid assignments outside the visible window also reserve the same envelope, with unknown reservations propagating to visible unpaid items.
- Funding after due date remains explicitly late even when the envelope has enough funds. The conservative civil-date snapshot includes all cash received on or before openingDate; only later income contributes separately. Earlier/same-date income assignments show snapshotAlreadyIncluded and cannot supply coverage. Paid opening-cash assignments are excluded because the snapshot reflects them; paid assignments to income after the snapshot still reserve that income, even outside the visible window.
- A what-if draft stores its base revision. Applying after another edit requires review/rebase rather than silently overwriting current data. Apply/discard is explicit and undoable; draft changes never mutate the saved plan.
- No automatic money movement, loan recommendations or solvency promises.

### Dual-screen seam
`PaydayWorkspaceLayout` composes bill timeline and envelope/draft controls. Standard single-screen iPhone navigation now; future iPhone Duo split keeps timeline context while editing funding. Preserve stable selection and unsaved draft state across layout changes. Future fold APIs are an adapter only after available and measured; iPad remains opt-in, not an MVP target.

## Milestones and dependency order
1. Native project, shared scheme, pure-Swift package, exact-pin Apple CI and privacy/platform contract gates (#1).
2. Money/date domain, recurrence and explainable envelope evaluator (#2; depends #1).
3. Durable validated storage and revision-safe drafts (#3; depends #2).
4. End-to-end worksheet editor, assign/reassign, paid/undo and what-if apply/discard (#4; depends #3).
5. VoiceOver, large text and compact layout continuity through PaydayWorkspaceLayout (#5; depends #4).
6. Bounded JSON import/backup, transactional restore and CSV export (#6; depends #3/#4).
7. Generated icon, listing reconciliation and proven signing/TestFlight release Action (#7; depends #1–#6).

## Testing strategy
Pure-Swift checks: fractional precision, currency validation, leap/month-end recurrence, date/timezone changes, unknown bill amounts, expected versus confirmed income, opening-cash double-count prevention, exclusive assignment, late funding, overcommitment and paid/reopen semantics. Storage fixtures cover corrupt/truncated JSON, failed writes, future schema and revision conflict. Import tests prove no partial replacement and recoverable failed restore. Native CI builds exact PR head and checks built Info.plist/device family; XCUITest covers create plan, assign a bill, observe shortfall, draft a changed pay date, discard/apply and export. VoiceOver/manual accessibility checks require honest evidence; no Linux parse-only result substitutes for native build/UI tests.

## Packaging and distribution
Use `com.infinityball.paydaybridge` in PRODUCT_BUNDLE_IDENTIFIER, Info.plist and every signing configuration; `TARGETED_DEVICE_FAMILY = 1` must survive project regeneration.
Maintain `AppStore/description.txt` and generate actual `AppStore/icon.png` with hermes-image-gen after analyzing repo and copy; issue #7 carries the exact brief. Require square opaque edge-to-edge graphics without text, marketing, border or baked corner radius; wire the same file into the Xcode AppIcon catalog and verify archived icon resources. No placeholder claim or substitution if model unavailable.
Implement `.github/workflows/release.yml` ported from rwrife/cook-console: `v*` tags/manual dispatch, macos-26, measured Xcode 26.0.1/17A400 and iOS 26+ SDK, signed IPA archive/export, ASC API upload, processing wait, GitHub release. Secret names only: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`; API key file mode 600 and always-cleanup. Native app record/signing setup and processed TestFlight build remain required release evidence; bundle registration is not release completion.

## Risks, privacy and explicit non-goals
Manual numbers can be stale or incomplete: always show snapshot date, assumptions and unknown warnings. Due dates do not establish a grace period or bank settlement time. No financial/tax/investment advice, guarantee, payments or emergency claims. Device-local file protection and explicit exports; OS backups may leave the device. No accounts/cloud/bank sync, trackers or sensor permissions. No Android/native iPad, multi-currency, generic expense ledger or collaboration.
No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity or hybrid/cross-platform equivalents. No unavailable dual-screen SDK requirement. M1 introduces the launch-only app, project, package and CI; it does not implement the worksheet, generated icon, release workflow or TestFlight upload. A native build claim requires a green exact-head macOS CI run.
