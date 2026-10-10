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
Documentation/backlog only. No application source, Xcode project, CI, generated icon, release Action, build or TestFlight upload exists yet. See PLAN.md and issues #1–#7. Platform pins are planning declarations until measured in CI.

## Development quickstart (after issue #1)
Use macOS with measured Xcode 26.0.1/17A400 and iOS 26+ SDK. Clone, open the shared PaydayBridge Xcode scheme, and run on an iPhone simulator. Future pure-Swift domain checks use `swift test`; Linux/Docker evidence does not establish SwiftUI compilation or built device-family metadata. No build command exists in this scaffold yet.

## Store and distribution contract
`AppStore/description.txt` is pre-release copy; reconcile it with implemented features before release. Generate real `AppStore/icon.png` after the skeleton exists using the requested `hermes-image-gen` model and the exact issue #7 brief; verify opaque square edge-to-edge artwork and Xcode asset wiring. No placeholder icon or silent model substitution.

Issue #7 must implement `.github/workflows/release.yml` by porting the proven rwrife/cook-console publish template: `v*` tag or manual dispatch, macos-26, exact Xcode/iOS 26+ checks, mode-600 ASC key, signed IPA archive/export, TestFlight upload, processing wait and GitHub release. Secrets configured by name: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`; never log values. Registration of the bundle ID does not establish an app record, signing readiness or store approval. Require real run URL, archive metadata and processed build evidence before claiming distribution.

MIT licensed.
