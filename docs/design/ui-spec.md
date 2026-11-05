# VirtSpace UI/UX Audit and Redesign Spec

Status: proposal, 2026-11-05. Audited at `main` `bb90015` (iOS code identical to `e8ec6bd`, capture v2 merged). Output is a design spec, not code. Login/auth is out of scope: the dev-auth flow stays invisible.

Read with `spec-doc.md` §6 (UX intent), §7.1 (API, including `:retry` from branch `feat/backend-state-retry`) and §10 (ledger: R18, R24, R25, R31, R32 touch this spec).

How the audit was done: every SwiftUI file in `VirtSpace/VirtSpace/` read in full, plus the backend status model (`backend/src/db/schema.ts`), progress writers (`backend/src/worker.ts`) and route error codes (`backend/src/routes/worlds.ts`). One cold-launch screenshot was taken on a throwaway iPhone 18 Pro simulator (iOS 27) against a dead localhost port. That simulator has since been deleted. Simulator tap automation (`xcodebuildmcp ui-automation` / axe) fails under Xcode 27 because SimulatorKit moved, so every other state was audited from code. File references are `path:line` relative to `VirtSpace/VirtSpace/` unless they start with `backend/`.

---

## 0. Top findings (ranked)

Feedback-accuracy bugs come first.

1. **A failed library load looks like an empty library.** On a load error `hasLoadedOnce` becomes true and the empty state reads "No worlds yet" (`Features/Library/LibraryView.swift:91-93`, `:134`). The only sign of the error is a toast that disappears after 4 s. A user who is offline sees their whole library as gone.
2. **A new scan does not show up in the Library.** After an upload succeeds, the Capture tab shows a success toast and switches tabs 0.7 s later (`Features/Capture/CaptureScreenModel.swift:230-234`). The toast belongs to the Capture screen, so it vanishes with the tab switch. The Library reloads only on its first appearance (`LibraryView.swift:90-96`, `hasLoadedOnce`), so once the Library has been opened before, the new world is missing until the user pulls to refresh. The same staleness hits a world deleted from Detail (`Features/Library/WorldDetailView.swift:356-365`): it dismisses with no confirmation and the deleted card stays in the list (tapping it gives a 404 toast).
3. **Generation progress is invented, but shown as a real percentage.** The worker writes elapsed-time pseudo-progress for `generating_draft` / `generating_hq`, linear against 45 s / 360 s and capped at 95 (`backend/src/worker.ts:176-182`, `:993-997`; `backend/src/config.ts:85-86`). The app shows it as "37%" with a determinate bar (`LibraryView.swift:333-340`). An HQ run that takes longer sits at "95%" for minutes. On top of that, `progress` resets to null at every status change (`backend/src/db/schema.ts:82-85`), so the Library bar runs 0 to 100 for stitching and then jumps back to 0 for generating.
4. **Failure states show raw status strings and the wrong severity.** Detail prints "failed generating hq" (`WorldDetailView.swift:176-180`). The chip says "Failed" in red for every `failed_*` (`Core/Models/Models.swift:88`, `:114`), even for `failed_generating_hq`, where the draft world still opens in 3D. There is no retry for any failure (R18, R42). The backend `:retry` endpoint exists on `feat/backend-state-retry`, but the app has no UI for it.
5. **Error copy is inaccurate or leaks internals.** Every 402/429 is mapped to "Daily scan quota or credit budget reached" (`Core/API/APIClient.swift:251-253`, `Core/API/APIError.swift:23-24`), including `rate_limited` from a quick double tap. 401/403 shows "Check the dev-auth token in Secrets" (`APIError.swift:21-22`). Server errors show "Server error (409): not_enhanceable". A parked upload produces "Server error (0): This upload is paused…" because a local condition is wrapped as `APIError.server(0, …)` (`Core/Capture/CaptureUploader.swift:367`). The upload-failure toast appends the raw error in parentheses and is cut off at 3 lines (`CaptureScreenModel.swift:177`).
6. **Enhance can fail later with no explanation.** The enhance route does not check the daily credit budget. The worker then parks the job (`BudgetExceededError`) and the world becomes `failed_generating_hq`, shown as a plain "Failed" (`backend/src/worker.ts:1171-1196`). The success toast "Enhancing to HQ — this takes a few minutes" is honest at that moment, but nothing tells the user why it failed later. There is also no cost confirmation before a 1500-credit action.
7. **Opening a world shows two progress bars, then risks a permanent black screen.** Detail downloads the splat with an inline "Preparing… 43%" button (`WorldDetailView.swift:207-223`, `:287-309`). Then `ExplorerView` opens with its own 0 to 100 "Rendering splats" ring (`Features/Explorer/ExplorerView.swift:129-160`). That is two bars, one after the other, plus jargon. There is no `webViewWebContentProcessDidTerminate` handler (`ExplorerView.swift:328-383`; R31), so a killed WebGL process leaves a black screen with no error and no retry.
8. **Status freshness copy misleads.** "working · updated 12s ago" (`LibraryView.swift:357`) is jargon and only updates every 3 s. "Taking longer than usual — still trying" fires after 90 s of heartbeat age (`:351-356`), which also happens when the job is only queued, or when the phone is offline and polling fails silently (`LibraryView.swift:202`, `WorldDetailView.swift:333`). The app ends up blaming the server for the client's connection. Detail also keeps polling a deleted (404) world forever, because errors are swallowed and the status never changes.
9. **The Library silently stops at 20 worlds.** `GET /v1/worlds` defaults to `limit=20` (`backend/src/routes/worlds.ts:154`) and the client ignores `has_more` (`APIClient.swift:184-188`).
10. **There is no onboarding, consent, or permission priming, and accessibility is thin.** Photos upload before any terms or consent (R32). The camera prompt fires cold from "Start capture" (`CaptureScreenModel.swift:144-155`). A denial gives a toast with no "Open Settings" action. Across the app: 3 accessibility labels in total, no Reduce Motion handling (repeating spinners `ExplorerView.swift:276`, `Features/Preview/PanoPreviewView.swift:272`; a white full-screen flash per shot, `Features/Capture/HUD/CaptureHUDView.swift:221-227`), about 20 fixed `.font(.system(size:))` sizes, and 38-40 pt icon buttons. The privacy text and the Info.plist both declare location use that nothing performs (R32). An emoji ships in the quota notice (`Features/Capture/CaptureStartView.swift:124`).

---

## 1. Design principles

1. **Content is the hero, chrome is glass.** Thumbnails, the camera feed and the 3D world are the only rich surfaces. Everything else is flat: solid system backgrounds, no gradients, no shadows. Liquid Glass appears only where the system puts it (bars, sheets, menus) and on controls floating over the camera or the 3D canvas.
2. **Never claim more than we know.** Determinate progress only for measured work (bytes, frames, stitch). Estimated work gets an indeterminate indicator and a plain time range. Success is shown only after the server confirms. A failure always says what still works and what to do next.
3. **One voice, one word per thing.** The user scans a **space**, sees it in the **Library**, **explores** it in 3D, views its **360° photo**, and can **improve quality**. Never "world", "splat", "pano", "draft", "HQ", "frames", "stitch" or "reconstruct" in user-facing copy (debug screens excepted).
4. **Teach once, at the moment it matters.** Three-step onboarding, then coaching inside the first scan. Permissions are asked just in time, after a one-line reason.
5. **Calm motion with a purpose.** Animate state changes (shot taken, status changed, space ready), never decoration. Every animation has a Reduce Motion fallback. Haptics mark outcomes, not every frame.

### Reconciling "clean modern flat" with iOS 26/27 Liquid Glass

Apple positions Liquid Glass as the material of the *controls and navigation layer* that floats above content, and says the content layer should use standard materials and backgrounds. Putting glass in content muddles hierarchy, and custom glass should be rare ([HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [WWDC25 219 Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/), [WWDC25 356 Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)). That fits the owner's ask exactly:

- **Flat content.** Library cards, Detail sections, Settings rows and onboarding pages use solid `systemBackground` / `secondarySystemGroupedBackground` fills. Remove the indigo radial backdrop (`Features/Capture/CaptureView.swift:164-175`), the gradient placeholders (`LibraryView.swift:266-272`, `WorldDetailView.swift:117-123`) and the tinted toast strokes (`Core/UI/ToastModifier.swift:69-72`).
- **System glass for free.** `TabView`, `NavigationStack` toolbars, sheets, menus and confirmation dialogs already render Liquid Glass when built with Xcode 27 (visible in the launch screenshot: a floating glass tab bar). Do not add custom backgrounds to bars, because that turns the system glass off ([WWDC25 323 Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)).
- **Custom glass, used deliberately, in one place:** controls floating over live media (the capture HUD close button, bottom progress capsule and coaching banner; the Explorer and 360° close/save buttons; the toast). This is the same role glass plays in Apple's Camera app. Use `.glassEffect(.regular, in: .capsule)` or `.buttonStyle(.glass)` in place of the current `.ultraThinMaterial`, grouped in a `GlassEffectContainer` where controls sit together.
- Reduce Transparency is handled by the system for glass. The flat surfaces need nothing.

Why: flat content keeps attention on the scans and holds up in light mode. Glass limited to controls over media is what users already expect from iOS 26/27, so the app reads as native rather than themed.

Sources consulted for capture and onboarding patterns: Polycam's guided mode and preparation guidance (start with a guided mode for first-timers; turn on the lights; enable Do Not Disturb; no account needed to start) ([Getting Started](https://learn.poly.cam/hc/en-us/articles/39279656782996-Getting-Started-with-Polycam), [Guided Mode](https://learn.poly.cam/hc/en-us/articles/35619450890132-How-to-Use-Guided-Mode-in-Polycam), [Preparing to Scan](https://learn.poly.cam/hc/en-us/articles/48538689020692-Preparing-to-Scan)); Scaniverse support ([How to use Scaniverse](https://api-dev.scaniverse.com/support)); Apple RoomPlan's coaching model (short, imperative, one instruction at a time, live feedback in the view) ([WWDC22 10127](https://developer.apple.com/videos/play/wwdc2022/10127/), [RoomPlan docs](https://developer.apple.com/documentation/roomplan)); HIG [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding), [Privacy: requesting permission](https://developer.apple.com/design/human-interface-guidelines/privacy), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts), [Motion](https://developer.apple.com/design/human-interface-guidelines/motion), [Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics); SwiftUI motion and feedback ([WWDC23 10158 Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/), [WWDC23 10157 advanced animations: phaseAnimator / keyframes](https://developer.apple.com/videos/play/wwdc2023/10157/), [SensoryFeedback](https://developer.apple.com/documentation/swiftui/sensoryfeedback), [WWDC25 337 What's new in SF Symbols 7: Draw On/Off, variable draw](https://developer.apple.com/videos/play/wwdc2025/337/)). Two pages (HIG Materials, Adopting Liquid Glass) render client-side and could not be machine-quoted; the statements above paraphrase their published guidance and the WWDC25 sessions.

---

## 2. Tokens

Everything lives in one file (`Core/UI/Theme.swift`) as static members. No design-token framework.

### 2.1 Color (semantic)

The app follows the system appearance for Library, Detail, Settings and onboarding. Scan, Explorer and 360° are always dark: use `.environment(\.colorScheme, .dark)` on the Scan subtree plus `.toolbarColorScheme(.dark, for: .tabBar)` while that tab is selected, and `.preferredColorScheme(.dark)` inside the two full-screen covers. Drop the app-wide `.preferredColorScheme(.dark)` (`ContentView.swift:35`).

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg` | `systemBackground` | `systemBackground` | screens |
| `surface` | `secondarySystemGroupedBackground` | same | cards, sections |
| `surfaceInset` | `tertiarySystemFill` | same | placeholders, tracks |
| `textPrimary` | `label` | `label` | |
| `textSecondary` | `secondaryLabel` | `secondaryLabel` | meta, captions |
| `textTertiary` | not for text | not for text | dividers and icons only (contrast fails for text) |
| `accent` | `#0071A4` (5.4:1 on white) | `#64D2FF` (12:1 on black) | primary actions, current target, links. Replaces raw `.cyan` (`ContentView.swift:34`), which is about 1.9:1 on white |
| `onAccent` | white | black | label on accent fills |
| `success` | `systemGreen` | `systemGreen` | ready, captured |
| `warning` | `systemOrange` | `systemOrange` | coaching, slow, partial failure |
| `danger` | `systemRed` | `systemRed` | failed, destructive |
| `scrim` | black 60% | black 60% | behind full-screen overlays on camera |

Status color collapses from seven hues (`Models.swift:105-116`) to three meanings: in progress = `accent`, ready = `success`, needs attention = `warning` / `danger`. Color is never the only signal: every status also has a word and a symbol.

### 2.2 Type (SF Pro, Dynamic Type text styles only)

| Role | Style | Notes |
|---|---|---|
| Screen title | `.largeTitle` via `navigationTitle` + `.large` display mode | Library, Settings |
| Page title (onboarding, empty states) | `.title2.bold()` | |
| Section / card title | `.headline` | `lineLimit(2)`, not 1 |
| Body | `.body` | |
| Secondary | `.subheadline` + `textSecondary` | |
| Meta, captions | `.footnote` / `.caption` | never `.caption2` for meaningful text |
| Numbers | add `.monospacedDigit()` + `.contentTransition(.numericText())` | counters, percentages |
| HUD | `.headline` / `.subheadline`, clamped with `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` | camera overlays must not cover the target |

Replace every `.font(.system(size:))` on text and icons with a text style, or with `@ScaledMetric` for icon sizes (for example `CaptureStartView.swift:23`, `CaptureHUDView.swift:136-138`, `:168`, `:236`, `WorldDetailView.swift:147`, `LibraryView.swift:132`, `:296`). Drop `.ultraLight` / `.light` symbol weights: use `.symbolRenderingMode(.hierarchical)` at the text weight.

### 2.3 Spacing, radii, elevation

- Spacing scale: `4, 8, 12, 16, 24, 32, 48`. Screen side margin is 16 (system default; use `.contentMargins` / `.scenePadding`). Card inner padding is 16. Gap between cards is 16. Gap between sections is 24 to 32.
- Radii: `12` (small surfaces, thumbnails inside cards), `20` (cards, sections), capsule (buttons, pills, banners, toasts). Nest radii concentrically: inner radius = outer radius minus padding.
- Elevation: none in content. The glass layer is the only depth. No `.shadow` on content. The glow shadows on capture dots stay because they sit over camera video.
- Touch targets: at least 44x44 pt everywhere (`.frame(minWidth: 44, minHeight: 44)` or `.contentShape`).

### 2.4 Motion

| Token | SwiftUI | Use |
|---|---|---|
| `quick` | `.snappy(duration: 0.2)` | pills, toggles, small state swaps |
| `standard` | `.smooth(duration: 0.35)` | appear/disappear, overlays, progress values |
| `emphasis` | `.spring(duration: 0.45, bounce: 0.2)` | shot confirmation, space-ready moment |
| `exit` | `.easeOut(duration: 0.2)` | dismissals |

Rules: animate only state changes. No looping decoration, except one indeterminate indicator while real waiting happens. Never animate a progress value backwards (hide the bar and show a new one instead). Read `@Environment(\.accessibilityReduceMotion)`. When it is on, replace move/scale/blur with an opacity crossfade, stop repeating animations (show a static symbol plus text), skip the shot flash, and skip symbol bounces.

### 2.5 Haptics map

Use `.sensoryFeedback(_:trigger:)` from views and the existing feedback generators in the capture engine. One haptic per outcome, never per frame.

| Moment | Feedback | Today |
|---|---|---|
| Shot captured | `.impact(weight: .medium)` | yes (`Features/Capture/Engine/ShotPipeline.swift:190-194`) |
| Sweep finished / scan complete | `.success` | yes (`ShotPipeline.swift:197-201`, `CaptureEngine.swift:586`) |
| Target locked (aligned) | `.selection`, once per target | no |
| Drift hard warning appears | `.warning`, once per episode | no |
| Upload finished, server confirmed | `.success` | no |
| Space became ready while visible | `.success`, once per space | no |
| Retry / Improve accepted by the server | `.impact(weight: .light)` | no |
| Error toast | `.error` | no |
| Saved to Photos | `.success` | no |
| Destructive confirm | none (system dialog) | n/a |

---

## 3. Navigation and information architecture

```
TabView (system Liquid Glass tab bar)
 ├─ Library  (square.grid.2x2)    NavigationStack(path: router.libraryPath)
 │    ├─ Space detail             push
 │    │    ├─ Explore in 3D       fullScreenCover (dark)
 │    │    └─ 360° photo          fullScreenCover (dark)
 │    └─ toolbar trailing: Settings (gearshape) → sheet
 └─ Scan     (viewfinder)         camera flow, always dark
Onboarding: fullScreenCover over the TabView until terms are accepted (version-gated)
```

- **Two tabs stay** (locked v1 scope, spec §1). Rename "Capture" to **Scan**, the word users use. **Library comes first**, and the last-used tab is remembered with `@SceneStorage`. A first launch lands on Scan after onboarding.
- **Settings stays a sheet** from a trailing gear on the Library toolbar. Settings is used rarely, has no third destination worth a tab, and a sheet keeps the tab bar to the two jobs. Move it from leading to trailing, where iOS 26 puts secondary actions.
- **After an upload succeeds**, switch to Library and push the new space's Detail, so the user watches it build. This needs a small app-level `AppRouter` (`@Observable`: `selectedTab`, `libraryPath`, `open(worldId:)`) in place of the `switchToLibrary` closure (`ContentView.swift:22`).
- The 5-tap debug gesture on the Library title (`LibraryView.swift:56-60`, `:150-161`) stays, but on a proper `navigationTitle` via `.onTapGesture` on the toolbar title, so the title keeps its header trait. The DEBUG ladybug button stays DEBUG-only.

---

## 4. Per-screen audit and layouts

### 4.1 App shell (`ContentView.swift`, `VirtSpaceApp.swift`)

Shows a two-tab `TabView`, forced dark, tint `.cyan`.
Issues: forced dark everywhere (`:35`); the `.cyan` tint fails contrast in light mode (`:34`); the capture tab is first and is the default (`:18`); no onboarding gate; the launch recovery kick (`VirtSpaceApp.swift:63-67`) is invisible, which is correct, but its outcome toasts appear on the Capture screen only.
Proposed: section 3. The onboarding gate is `fullScreenCover(isPresented: !consent.isCurrent)`. One app-level toast host (section 7.1).

### 4.2 Scan: start screen (`Features/Capture/CaptureStartView.swift`, `CaptureView.swift`)

Shows a viewfinder icon, the title "Guided 360° Capture", a long instruction sentence, a cyan Start button, quota notices, pending-upload controls, and DEBUG tools.
Issues:
- Layout: content is centered by `Spacer`s, so with DEBUG tools present the primary button floats mid-screen (screenshot). Decorative radial gradient (`CaptureView.swift:164-175`). 56 pt `.ultraLight` icon (`:22-24`). Instructions crammed into one 2-sentence paragraph (`:29`).
- Copy: "Guided 360° Capture" is product jargon. The emoji (`:124`). "Upload paused after 5 failed attempts" exposes mechanics (`:83`).
- Interaction: when the quota is exhausted the button greys out but keeps saying "Start capture" (`:66-73`). Camera denied shows only a toast, with no "Open Settings" (`CaptureScreenModel.swift:153-155`). The failure message from a failed capture is small red footnote text with no icon (`:35-41`).
- Accessibility: fixed icon size; the button has no hint; the quota hint uses `.white.opacity(0.5)` (`:48`), which passes but is close.

Proposed layout (dark, flat):

```
┌──────────────────────────────┐
│                              │
│  Scan a room                 │  title2 bold, leading-aligned
│  Stand in the middle, then   │  body, secondary
│  follow the dots around you. │
│                              │
│  ┌ 1  Stand in the middle ─┐ │  three compact rows, symbol + one line
│  ┌ 2  Turn the phone, not  │ │  (same steps as onboarding; tap "How to
│  │    your feet            │ │   scan" for the full version)
│  ┌ 3  Turn on the lights ──┘ │
│                              │
│  [ banner slot ]             │  quota / pending upload / camera denied
│                              │
│  ( Start scan )              │  full-width capsule, accent, 50 pt high
│  3 scans left today          │  footnote, only when < 5 left
└──────────────────────────────┘  DEBUG tools under a "Developer" disclosure
```

States:
- **Ready**: as above.
- **Quota reached**: banner "You've used today's scans. More at 4:00 PM." Button disabled, label "Scan unavailable today".
- **Pending upload (retrying automatically)**: banner "1 scan waiting to upload. It will retry when you're online." with "Upload now".
- **Pending upload (parked)**: banner "1 scan couldn't upload. It's saved on this phone." with "Try again" and "Delete scan" (confirmation).
- **Camera denied**: banner "VirtSpace needs camera access to scan." with "Open Settings" (`UIApplication.openSettingsURLString`). This replaces the toast.
- **Last scan failed**: banner (warning) with the cause from the copy deck plus "Scan again".
- **Starting**: "Starting camera…" (keep, `CaptureView.swift:58-64`).

### 4.3 Scan: capture HUD (`HUD/CaptureHUDView.swift`, `HUD/CoachingLayer.swift`, `HUD/ProgressSphereView.swift`, `HUD/PivotIndicatorView.swift`)

Shows world-locked dots, a reticle with a dwell ring, an edge chevron with degrees, a top coaching banner, a close button, an "Exposure locked" pill, and a bottom capsule with the target label, status line, progress sphere, count and pivot indicator. It also shows low-light and lost-tracking cards.
Issues:
- Copy: target labels ("Horizon 3", "Up 2", "Down 4") mean nothing to users (`Engine/TargetLayout.swift:63-67`). "Steady…" versus "Hold still…" is confusing (`:299-305`). "Exposure locked" is jargon and reads as a warning (`:245-260`). Coaching lines are long. ARKit strings such as "Tracking limited" are opaque (`Engine/ARKitCaptureSource.swift:305-320`). The failed-shot message "Couldn't save frame N: <error>" is raw (`ShotPipeline.swift:131`).
- Feedback: the full-screen white flash at 0.55 opacity fires on every shot, ignores Reduce Motion and can bother photosensitive users (`:221-227`). No haptic on lock-on. The drift hard warning has no haptic. The "Got it" state lasts 0.25 s and reads as a flicker (`:276-280`).
- Accessibility: close button 38 pt (`:238`); no VoiceOver announcements of progress; HUD text not clamped; captured checkmarks are 7 pt (`:137-138`).

Proposed:
- Bottom capsule (glass): `[sphere] 12 of 28 · [pivot]`. The line above it says what to do: **"Turn right"** / **"Tilt up"** / **"Point at the ceiling"** / **"Point at the floor"** with the degrees in small text, then **"Hold still"** once aligned (the dwell ring shows the hold). Drop the target labels.
- Remove the "Exposure locked" pill. Show the exposure problem only when locking fails (the existing one-time banner).
- Shot confirmation: the reticle fills, a check draws on (`Image(systemName: "checkmark").symbolEffect(.drawOn)`, `emphasis`), the facet fills in the sphere, a medium impact plays, and a soft 0.2-opacity flash runs for 120 ms. Under Reduce Motion there is no flash and no scale.
- VoiceOver: announce "Photo 12 of 28" after each shot, and the direction instruction when the target changes (throttled to once per 2 s).
- The low-light and lost-tracking cards keep their behavior with the new copy. Buttons at least 44 pt, glass.

### 4.4 Scan: upload overlay (`HUD/UploadOverlayView.swift`)

Shows a ring with "12/28", "Uploading your space…" and "Keep VirtSpace open — this only takes a moment."
Accuracy: the ring counts JPEG frames only. Depth PNGs upload between frames, and `frames:done` runs after 28/28, so the ring sits at 28/28 with no change of label (`Core/Capture/CaptureUploader.swift:457-495`). "Only takes a moment" is a promise the app cannot keep on a slow network. "Keep open" is honest until R25 (background uploads) lands.
Proposed:

```
        ( ring 12 of 28 )
      Uploading photos
   Keep VirtSpace open until this finishes.
```

When `uploaded == total`, the label becomes "Finishing up…" with an indeterminate ring. On success: success haptic, then route to the new space's Detail (section 3). On failure: dismiss the overlay and show the start-screen banner (not a toast) with the cause and "Try again". Once R25 lands, change the line to "You can leave the app. We'll keep uploading."

### 4.5 Library (`Features/Library/LibraryView.swift`)

Shows one card per world (150 pt thumbnail, title, place · relative time, status chip), an upload or progress bar and a heartbeat caption, with pull to refresh and 3 s polling.
Issues:
- Accuracy: findings 1, 2, 3, 8 and 9. The relative time ("2 minutes ago") does not tick (`:300-303`). The "Loading…" and "No worlds yet" text share one view (`:134`).
- Layout: thumbnail 150 pt fixed (`:289`), so the content (2:1 panoramas, 16:9 thumbnails) is cropped arbitrarily. Title `lineLimit(1)`. The "·" separator is read aloud. Gradient placeholder.
- Interaction: no context menu (delete, retry), no insert or remove animation, `ProgressView()` spinner in each loading thumbnail.
- Accessibility: card is not a single element, has no label and no hint; status is partly color-only in the progress tint.

Proposed layout:

```
Library                               (gear)
┌──────────────────────────────────┐
│ [ thumbnail 16:9, radius 12 ]    │
│ Nov 5, 3:12 PM          ● Ready  │  headline + pill
│ A bright living room with a…     │  caption, 2 lines, secondary
└──────────────────────────────────┘
┌──────────────────────────────────┐
│ [ placeholder, symbol ]          │
│ Nov 5, 3:40 PM     ◌ Building    │
│ Step 2 of 2 · Building your space│
│ ▭▭▭▭▭▭▭▭▭▭ (indeterminate)       │
└──────────────────────────────────┘
```

- One column, card = thumbnail at 16:9 `aspectRatio(.fill)` plus a text block (16 pt padding). Title: the date in `Nov 5, 3:12 PM` form (strip the `Scan ` prefix the uploader adds, `CaptureUploader.swift:369`). Subtitle: the first line of `caption` once ready. Renaming needs a `PATCH` endpoint and is backlog.
- **States:**
  - Loading (first load): 2 redacted placeholder cards (`.redacted(reason: .placeholder)`), no spinners.
  - Empty (load succeeded, zero worlds): `ContentUnavailableView("No spaces yet", systemImage: "cube.transparent", description: "Scan a room and it will show up here.")` with a "Scan a room" button that switches tab.
  - Error with nothing cached: `ContentUnavailableView("Can't load your library", systemImage: "wifi.exclamationmark", description: <cause>)` with "Try again".
  - Error with data cached: keep the cards, and show a top inline banner "Offline. Showing your last update." after 2 consecutive failed polls. Hide it on the next success.
  - Per-card status: section 7.4.
- Pagination: load the next page when the last card appears (`has_more`, `cursor`).
- Context menu on a card: "Delete" (confirmation), plus "Try again" on retryable failures.
- Relative time: `Text(date, style: .relative)` ticks for free. Alternatively `TimelineView(.periodic(from: .now, by: 60))`.
- Accessibility: `.accessibilityElement(children: .combine)`, label "Space from Nov 5 at 3:12 PM, Ready", hint "Opens details".

### 4.6 Space detail (`Features/Library/WorldDetailView.swift`)

Shows a hero thumbnail, title + chip, date, a raw failure label, a 6-row status timeline, a caption card, and 4 stacked full-width buttons (Explore, 360°, Enhance, Delete).
Issues:
- Accuracy: findings 2, 4, 6, 7 and 8. Enhance flips status optimistically before the server answers (`:343-346`). The timeline lists "Enhancing" and "Complete" as unfinished on a `draft_ready` world, which suggests the space is not done (`:386-393`). The initial refresh hides errors when opened from a list item (`:92`), so stale list data is shown as truth.
- Layout: four equal-weight stacked buttons, with Delete as prominent as Explore. Enhance stays visible but disabled on `complete` worlds. The "Caption" label in uppercase is noise. "Preview appears when ready" uses tertiary text, which fails contrast (`:148-151`).
- Accessibility: timeline markers have no state labels; disabled buttons give no reason.

Proposed layout:

```
< Library                     (•••)  menu: Save 360° photo, Delete
┌──────────────────────────────────┐
│ [ hero thumbnail 16:9 ]          │
└──────────────────────────────────┘
Nov 5, 3:12 PM               ● Ready
Living room · 2 min ago
A bright living room with a sofa… (caption, expandable)

( Explore in 3D )                   prominent, full width
( View 360° photo )                 bordered, full width

┌ Improve quality ───────────────┐  surface card, only when draft_ready
│ Build a sharper version. Takes │
│ about 5 to 10 minutes.  [Start]│
└────────────────────────────────┘
```

- **Building** (uploading, stitching, generating_draft): the hero is a placeholder with an indeterminate shimmer (static under Reduce Motion). Below it, a **step list** of 3 steps: *Uploading photos* / *Combining photos* / *Building your space*. Done steps get a check. The current step gets a spinner or a real bar (stitch, upload). Future steps are grey. The action buttons are hidden, not disabled. Line: "Usually 1 to 2 minutes. You can leave this screen."
- **Ready** (draft_ready): primary actions plus the Improve quality card. Improve opens a confirmation sheet (section 7.5).
- **Improving** (generating_hq): Explore stays enabled (the draft is still there). The card reads "Improving quality… usually 5 to 10 minutes. You can keep exploring." with an indeterminate indicator.
- **Complete**: Explore + 360°, plus a small "High quality" label next to the pill. No Improve card.
- **Failed**: a warning or danger card in place of the step list, with copy and a **Try again** button (section 7.4). Delete is in the `•••` menu, not a big red button.
- Delete flow: confirmation, then the server call. **Only after a 2xx** remove the card from the shared store, pop to Library, and show the toast "Space deleted." On error, stay and toast the cause.
- Polling: stop and show "This space was deleted." on 404.

### 4.7 Explore in 3D (`Features/Explorer/ExplorerView.swift`, `Resources/SparkViewer/viewer.html`)

Shows a full-screen WKWebView with the Spark viewer, an in-page joystick, a loading ring, a retry overlay, a one-time coach capsule and a close button.
Issues: finding 7 (double progress, "Rendering splats", no process-termination handler); close button 40 pt with no accessibility label (`:222-233`); the coach sits at a hard-coded `padding(.bottom, 170)` (`:202`); `title` is unused; the repeating arc ignores Reduce Motion (`:269-279`); the joystick in `viewer.html` has no accessible alternative.
Proposed: Detail presents the cover immediately with `.remote` (that path already exists, `:96-110`) and the cover owns the whole loading arc. Step 1 is "Downloading · 12 of 40 MB", determinate, from bytes. Step 2 is "Opening your space", determinate, from Spark load progress. Each step is labelled, so one bar never runs 0 to 100 twice unexplained. Add `webViewWebContentProcessDidTerminate` that routes to the error overlay ("This space closed unexpectedly." / "Reload"). Top bar: glass close button (44 pt, label "Close") and the space title in `.headline`. The coach stays one-time, positioned relative to the joystick (pass the joystick's frame from the page, or anchor 24 pt above `#stick`).

### 4.8 360° photo (`Features/Preview/PanoPreviewView.swift`)

Shows a SceneKit sphere, loading/error overlays, a close button, a save button and a hint capsule.
Issues: icon-only buttons with no labels and 40 pt targets (`:209-225`); "The downloaded panorama couldn't be decoded." (jargon, `:96`); the save error shows raw `localizedDescription` (`:123`); a Photos permission denial gives no path to Settings; it opens facing about 180 degrees (HANDOFF carry-over); the hint never goes away.
Proposed: glass close/save (44 pt, labels "Close", "Save to Photos"); the hint fades out after the first drag; save success gives a toast plus a success haptic; a denied permission gives an alert "Allow VirtSpace to add photos in Settings." with "Open Settings" / "Cancel"; open facing longitude 0.

### 4.9 Settings (`Features/Settings/SettingsView.swift`)

Shows About (version, dev user id), Storage (2 sizes, Clear cache), Attribution, a Privacy paragraph, DEBUG (fixture), and Account (Delete account, double confirmation, then a signed-out placeholder).
Issues: shows `Secrets.devUserId` (`:84-89`), which breaks "keep dev auth invisible". Delete account under dev auth wipes the single shared library for every install (R24). The privacy text claims location use (`:132-139`; R32). The paragraph is a wall of footnote text. "Clear cache" is styled destructive although it is harmless. After account deletion the Library behind the sheet still shows every world.
Proposed: section 8.

### 4.10 Debug (`Features/Debug/DebugLogView.swift`, `Features/Capture/CaptureDebugToolsView.swift`)

Shows a log viewer (refresh, level filter, empty and error states via `ContentUnavailableView`) and test-scan tools. These are fine as developer tools. Only change: on the Scan start screen, put the DEBUG tools inside a collapsed "Developer" `DisclosureGroup` at the bottom so they stop competing with the primary button (see the screenshot: "Run test scan" is as loud as "Start capture"). No copy pass. Developer jargon is acceptable here.

---

## 5. Onboarding (first launch to first finished space)

Gate: `UserDefaults` `onboarding.termsVersion` (Int) and `onboarding.termsAcceptedAt`. Onboarding shows when the stored version is below `currentTermsVersion`. A returning user with current consent never sees it. Bumping the terms version re-shows **only** the terms page. Re-viewable from Settings: "How to scan" (pages 2-4) and "Terms of use" (page 5, read-only once accepted).

```
1 Welcome ──▶ 2-4 How to scan (skippable) ──▶ 5 Terms + consent (required)
   ──▶ Scan tab ──▶ [Start scan] ──▶ 6 Camera priming (just in time) ──▶ system prompt
   ──▶ 7 First-scan coaching ──▶ upload ──▶ Detail (building) ──▶ 8 Ready moment
```

1. **Welcome**. Symbol `cube.transparent` (hierarchical, Draw On once). "Turn any room into a 3D space" / "Scan a room with your iPhone, then walk through it in 3D." Buttons: [Continue], and "Skip" (top trailing, goes straight to terms).
2. **Stand in the middle**. `figure.stand`. "Stand in the middle of the room" / "You'll stay on this spot for the whole scan, about 2 minutes."
3. **Turn the phone, not your feet**. `arrow.trianglehead.2.clockwise.rotate.90`. "Turn the phone, not your feet" / "Hold your phone at chest height and turn in place, keeping the phone over the same spot. Follow the dots."
4. **Good light**. `lightbulb.max`. "Turn on the lights" / "Bright, even light gives the sharpest result. Keep people and pets out of the room."
   Pages 2-4 use a paged `TabView` with a page indicator and a [Next] button. Each symbol plays one animation on appear (static under Reduce Motion).
5. **Terms + consent** (spec R32: one page, one prompt, nothing more):
   ```
   Before you scan
   • Your photos are uploaded to VirtSpace and to World Labs,
     which builds your 3D space.
   • Your spaces are private to you.
   • Your original photos are kept until you delete the space.
   • You can delete any space, or your data, at any time.
   Read the terms of use                (link, opens a sheet)
   ( Agree and continue )
   ```
   Not skippable. There is no Decline button: closing is not possible, and the app is unusable without it, which is acceptable for v1 self-testing. Add "Not now" only if browsing without consent is ever wanted. Record the version and date on agree. This is the gate before any photo leaves the device: the onboarding cover blocks the Scan tab, and the uploader refuses to start without current consent (a defensive check in `UploadManager`).
6. **Camera priming** (on the first tap of "Start scan", only when the status is `.notDetermined`). An inline sheet: `camera` symbol, "Allow camera access" / "VirtSpace uses the camera to take the photos for your scan. Photos are only taken while you scan.", [Continue] which triggers the system prompt. Denied: the start-screen banner (section 4.2).
7. **First-scan coaching** (only on the first scan, `onboarding.firstScanCoached`):
   - Before shot 0: a glass card over the camera, "Point at the blue dot and hold still. The photo takes itself." [Got it].
   - After shot 1: banner, 3 s: "Nice. Now turn to the next dot."
   - First drift past the soft gate: banner "Keep the phone over the same spot. The dot below shows where it is." plus a one-time pulse on the pivot indicator.
   - Sky and floor targets: the instruction line uses "Point at the ceiling" / "Point at the floor by your feet".
   - Last shot: success haptic plus "That's everything." then the upload overlay.
8. **First ready moment**: section 9 item 7. The Detail screen also shows a one-time tip under Explore: "Drag to look around. Use the stick to walk."

---

## 6. Copy deck

Rules: sentence case; plain verbs; no jargon (space, not world/splat/pano/draft/HQ); no emoji; no em-dash pile-ups in short UI strings; numbers as digits; errors say what happened plus what to do. "Current" quotes the code as it ships.

### Shell and tabs

| Where | Current | Proposed |
|---|---|---|
| Tab | Capture | Scan |
| Tab | Library | Library |

### Scan: start screen

| Where | Current | Proposed |
|---|---|---|
| Title `CaptureStartView.swift:26` | Guided 360° Capture | Scan a room |
| Body `:29` | Hold the phone at your chest and turn around it. Follow the targets — VirtSpace turns your surroundings into a walkable 3D world. | Stand in the middle, then follow the dots around you. |
| Steps (new) | none | 1 Stand in the middle / 2 Turn the phone, not your feet / 3 Turn on the lights |
| Button `:66` | Start capture | Start scan |
| Button after failure `:66` | Try again | Scan again |
| Button when quota is spent | Start capture (disabled) | Scan unavailable today |
| Quota notice `:121` | Daily scan limit reached — resets in 5 hours | You've used today's scans. More at {time}. |
| Quota sub `:124` | Your captures are precious; so are the credits (plus an emoji) | (remove) |
| Low quota `CaptureScreenModel.swift:96` | 3 scans left today | 3 scans left today |
| Parked notice `:83` | Upload paused after 5 failed attempts. Your scan is still saved on this device. | This scan couldn't upload. It's saved on this phone. |
| Retry button `:92` | Retry upload | Try again |
| Discard button `:97` | Discard scan | Delete scan |
| Discard dialog `:105-114` | Discard this scan? / Discard scan / Keep it / The captured frames are deleted from this device and can't be recovered. | Delete this scan? / Delete scan / Keep / The photos will be removed from this phone. This can't be undone. |
| Starting `CaptureView.swift:61` | Starting camera… | Starting camera… |
| Camera denied `CaptureScreenModel.swift:154` | Camera access is denied. Enable it in Settings → VirtSpace. | VirtSpace needs camera access to scan. [Open Settings] |
| Camera declined `:151` | Camera access is needed to capture your space. | VirtSpace needs camera access to scan. [Open Settings] |
| Missing plist `:141` | Camera permission text is missing from the build — capture is disabled. | (DEBUG only: keep the developer wording) |

### Scan: HUD and coaching

| Where | Current | Proposed |
|---|---|---|
| Target label `TargetLayout.swift:63-67, 117-118` | Horizon 3 / Up 2 / Down 4 / Sky / Ground | (removed, replaced by the direction line) |
| Direction, not aligned `CaptureHUDView.swift:304` | 12° away | Turn right / Turn left / Tilt up / Tilt down (12° in caption) / Point at the ceiling / Point at the floor |
| Aligned, moving `:302` | Steady… | Hold still |
| Aligned, dwell `:302` | Hold still… | Hold still |
| Shooting `:300` | Capturing… | (no text: the check animation says it) |
| Advancing `:277` | Got it | (removed: the haptic and the check cover it) |
| Counter `ProgressSphereView.swift:30` | 12/28 | 12 of 28 |
| Exposure pill `:250` | Exposure locked | (removed) |
| Exposure banner `CoachingLayer.swift:148` | Couldn't lock exposure — lighting may vary between shots | Lighting may change between photos. Avoid switching lights on or off. |
| Drift soft `:134` | Turn around the phone, not your body | Keep the phone over the same spot |
| Drift hard `:122` | Hold the phone at your chest and turn around it | You've moved. Step back to where you started. |
| Thermal banner `:112` | Phone is warming up — normal during capture | Your phone is getting warm. That's normal. |
| Tracking `ARKitCaptureSource.swift:310` | Tracking unavailable | Can't see the room. Point at something with detail. |
| Tracking `:312` | Getting ready… | Getting ready… |
| Tracking `:314` | Slow down | Turn more slowly |
| Tracking `:316` | Too dark or too plain — try more light | Too dark or too plain. Try more light. |
| Tracking `:318` | Re-finding your space… | Finding your place again… |
| Tracking `:320` | Tracking limited | Turn more slowly |
| Shot failed `ShotPipeline.swift:131` / engine transient | Couldn't save frame N: <error> | That photo didn't save. Hold still to try again. |
| Low light title `CaptureHUDView.swift:316` | Too dark — turn on lights | It's too dark |
| Low light body `:319` | Dim rooms scan noisy and blurry. | Turn on more lights for a sharper result. |
| Low light button `:322` | Continue anyway | Scan anyway |
| Lost track title `:342` | Lost track of the room | Lost your place |
| Lost track body `:345` | Point at what you were scanning, or start over. Restarting discards the shots so far. | Point at what you were scanning. Or start over (this clears the photos so far). |
| Lost track button `:348` | Restart scan | Start over |
| Abandon dialog `:59-66` | Abandon this scan? / Abandon scan / Keep capturing / The N shots taken so far will be discarded. | Stop scanning? / Stop and delete / Keep scanning / The {N} photos taken so far will be deleted. |
| Close a11y `:241` | Cancel capture | Stop scan |
| Thermal title `CaptureView.swift:134` | Paused to cool down | Paused to cool down |
| Thermal body `:137` | Your iPhone got too warm, so capture paused to protect it. Give it a moment, then resume — your progress is saved. | Your iPhone got too warm. Give it a minute. Your photos so far are saved. |
| Thermal buttons `:145`, `:152` | Resume capture / Abandon scan | Continue scan / Stop and delete |
| First-scan coaching (new) | none | Point at the blue dot and hold still. The photo takes itself. / Nice. Now turn to the next dot. / Keep the phone over the same spot. The dot below shows where it is. / That's everything. |
| VoiceOver (new) | none | Photo {n} of 28 |

### Scan: upload

| Where | Current | Proposed |
|---|---|---|
| Overlay title `UploadOverlayView.swift:48` | Uploading your space… | Uploading photos |
| Overlay sub `:51` | Keep VirtSpace open — this only takes a moment. | Keep VirtSpace open until this finishes. |
| Overlay at 28/28 | (unchanged 28/28) | Finishing up… |
| Success toast `CaptureScreenModel.swift:230` | Scan uploaded — watch it build in Library. | (no toast: route to Detail, which shows Building) |
| Failure toast `:177` | Upload failed — your scan is saved. Retry from here or relaunch. (<raw error>) | Banner: Upload didn't finish. Your scan is saved on this phone. {cause} [Try again] |
| Retry failed `:200` | Upload failed again — <reason> | Still couldn't upload. {cause} |
| Deferred `:202` | Upload not retried — <reason>. | (no toast for "already uploading" / "waiting": the banner shows state) |
| Nothing to resume `:196` | Nothing left to upload. | (no toast: the banner disappears) |
| Discarded `:211` | Scan discarded. | Scan deleted. |
| Resumed `:224` | Resumed N pending scan uploads. | (no toast: the card appears in the Library) |
| Parked guard `CaptureUploader.swift:367` | Server error (0): This upload is paused. Retry or discard it from the capture screen. | (typed local error; the banner shows "This scan couldn't upload…") |

### Library

| Where | Current | Proposed |
|---|---|---|
| Title | Library | Library |
| Loading `LibraryView.swift:134` | Loading… | (placeholder cards, no text) |
| Empty `:134-136` | No worlds yet / Capture a space and it will appear here. | No spaces yet / Scan a room and it will show up here. [Scan a room] |
| Error, nothing cached | (shows the empty state) | Can't load your library / {cause} [Try again] |
| Offline banner (new) | none | Offline. Showing your last update. |
| Card title | Scan Nov 5, 2026 at 3:12 PM | Nov 5, 3:12 PM |
| Upload line `:245` | Uploading 12/28 | Uploading photos · 12 of 28 |
| Heartbeat fresh `:357` | working · updated 12s ago | (removed) |
| Heartbeat stale `:355` | Taking longer than usual — still trying | Taking longer than usual |
| Percent `:337` | 37% | (stitch only, no number: bar only. Generation: indeterminate) |
| Settings a11y `:67` | Settings | Settings |
| Card a11y (new) | none | Space from {date}, {status} |
| Context menu (new) | none | Try again / Delete |

### Space detail

| Where | Current | Proposed |
|---|---|---|
| Nav title `WorldDetailView.swift:81` | {title} / World | {date title} |
| Loading `:74` | Loading world… | (placeholder layout) |
| Placeholder `:148` | Preview appears when ready / No preview yet | (no text: symbol only. Status text is below) |
| Failure label `:177` | failed generating hq (raw) | (status card, section 7.4) |
| Caption header `:186` | CAPTION | (removed: caption shown as a subtitle) |
| Explore `:216` | Explore in 3D | Explore in 3D |
| Explore loading `:211-213` | Preparing… 43% | (moved into the Explorer cover) |
| 360 `:230` | View 360° Photo | View 360° photo |
| Enhance `:242` | Enhance to HQ | Improve quality |
| Enhance toast `:348` | Enhancing to HQ — this takes a few minutes. | (no toast: the status card changes to "Improving quality…") |
| Delete `:253` | Delete World | Delete space (in the ••• menu) |
| Delete dialog `:99-110` | Delete this world? / Delete World / Cancel / This permanently removes the world and its assets. | Delete this space? / Delete / Cancel / It will be removed from your library and our servers. This can't be undone. |
| Deleted toast (new) | none | Space deleted. |
| No 360 toast `:270` | This world has no 360° photo yet. | (button hidden until available) |
| No 3D toast `:290` | This world has no 3D asset yet. | (button hidden until available) |
| Timeline `:386-393` | Uploading / Stitching / Reconstructing / Draft ready / Enhancing / Complete | Uploading photos / Combining photos / Building your space |
| Building line (new) | none | Usually 1 to 2 minutes. You can leave this screen. |
| Explore tip (new, once) | none | Drag to look around. Use the stick to walk. |

### Explorer and 360° photo

| Where | Current | Proposed |
|---|---|---|
| Loading title `ExplorerView.swift:135` | Preparing your world… | Opening your space |
| Loading detail `:156-157` | Downloading / Rendering splats | Downloading · {x} of {y} MB / Almost ready |
| Error title `:167` | Couldn't open this world | Couldn't open this space |
| Error body | <raw error> | {cause from the error map} |
| Process killed (new) | none (black screen) | This space closed unexpectedly. [Reload] |
| Retry `:178` | Retry | Try again |
| Coach `:196-197` | Drag to look around / Use the stick to walk | Drag to look around / Use the stick to walk |
| Close a11y | none | Close |
| Pano loading `PanoPreviewView.swift:139-142` | Loading 360° photo… / Downloading | Loading 360° photo |
| Pano error `:159`, `:84`, `:96` | Couldn't open this photo / Couldn't read this image. / The downloaded panorama couldn't be decoded. | Couldn't open this photo / This photo is damaged. Try again to download it fresh. |
| Pano hint `:198` | Drag to look around · pinch to zoom | Drag to look around. Pinch to zoom. |
| Saved `:125` | Saved to Photos. | Saved to Photos |
| Save failed `:123` | Couldn't save: <raw> | Couldn't save to Photos. [Open Settings] when denied |
| Save a11y | none | Save to Photos |

### Settings

Section 8 has the full layout. Strings:

| Where | Current | Proposed |
|---|---|---|
| Storage rows `SettingsView.swift:95`, `:99` | 3D worlds / 360° photos | 3D spaces / 360° photos |
| Empty size `:311` | Empty | None |
| Clear `:107` | Clear cache (red) | Clear downloads (normal tint) |
| Storage footer `:116` | Cached downloads only. Your worlds stay safe in the cloud and re-download on demand. Currently using X. | Downloaded copies of your spaces. Clearing them frees space; they download again when you open them. |
| Cleared `:239` | Cache cleared. | Downloads cleared |
| Attribution `:122` | 3D worlds generated using World Labs | 3D spaces are generated using World Labs. |
| Privacy `:132-139` | (paragraph incl. location) | Row: Terms of use (opens the onboarding terms page). Row: Privacy (short page, location claim removed) |
| User row `:84-89` | User: <dev id> | (removed in Release; DEBUG-only in Developer) |
| Delete account `:169`, dialogs `:183-201` | Delete account / Delete your account? / Continue / This is permanent / Delete Everything | Hidden under dev auth (R24). When real auth lands: Delete account / Delete your account? / Delete account / Cancel / All your spaces and scans will be erased. This can't be undone. (one confirmation: the dialog is the confirmation) |

### Errors (APIError, shown via toast or banner)

| Case | Current | Proposed |
|---|---|---|
| Offline / timeout / cannot connect | (system text, e.g. "Could not connect to the server.") | You're offline. Check your connection and try again. |
| 401 / 403 | Not authorized. Check the dev-auth token in Secrets. | Something went wrong signing in. (DEBUG appends the developer hint) |
| 429 `daily_scan_quota_exceeded` | Daily scan quota or credit budget reached. Try again later. | You've used today's scans. More at {retry_at}. |
| 429 `rate_limited` | (same quota text) | Too many tries. Wait a moment and try again. |
| 404 `world_not_found` | Server error (404): world_not_found | This space was deleted. |
| 409 `not_enhanceable` / `not_retryable` | Server error (409): not_enhanceable | (refresh silently; toast only if state did not change: "This space has already moved on.") |
| 5xx / `internal_error` | Server error (500): internal_error | Something went wrong on our side. Try again in a minute. |
| decoding / invalid response | Couldn't read the server's response. / Unexpected response from the server. | Something went wrong. Try again. |

### Permission strings (Info.plist via build settings)

| Key | Current | Proposed |
|---|---|---|
| `NSCameraUsageDescription` | VirtSpace uses the camera to capture 360° photos of your space. | VirtSpace uses the camera to take the photos for your 3D scan. |
| `NSPhotoLibraryAddUsageDescription` | Saves your 360° panoramas to Photos when you choose to download them. | Lets you save a space's 360° photo to your library. |
| `NSLocationWhenInUseUsageDescription` | Your location tags scans with the place they were captured (optional). | Remove (nothing uses location; R32) |

---

## 7. Feedback system

### 7.1 One toast component

Today: 6 independent `.toast` hosts (Capture, Library, Detail, Settings, Pano, debug), bottom-anchored, 4 s for every style, covered by sheets, lost when the tab switches.

Proposed:
- `ToastCenter` (`@Observable`, environment) with `show(_ message:, style:, action:)`. One host rendered in a **passthrough overlay `UIWindow`** above all scenes, so toasts stay visible over sheets and full-screen covers and survive tab switches. About 40 lines, no dependency.
- Placement: top, under the Dynamic Island, glass capsule (`.glassEffect`), symbol plus at most 2 lines, optional trailing action button ("Open Settings", "Try again"). Top placement avoids the tab bar, the capture bottom capsule and the Explorer joystick.
- Timing: info/success 3 s, error 5 s, with an action 6 s. While VoiceOver is running, no auto-dismiss below 10 s and the message is posted as an announcement. Swipe up or tap to dismiss.
- One at a time: a new toast replaces the current one. An identical message within 2 s is dropped (dedupe).
- Haptic per style: success `.success`, error `.error`, info none.
- Motion: move from top plus opacity, `quick`. Reduce Motion: opacity only.

### 7.2 Which surface for what

| Situation | Surface |
|---|---|
| Transient outcome of a user action (saved, deleted, cleared, action failed) | Toast |
| Ongoing condition (offline, quota spent, scan waiting to upload, camera denied) | Inline banner on the affected screen, stays until the condition clears |
| State of a space | Status pill + status card / step list (never a toast) |
| Destructive or costly decision | `confirmationDialog` (destructive) or a sheet with details (Improve quality) |
| Blocking question that needs a decision before continuing (Photos access denied while saving) | `alert` with 2 buttons |
| Never | A toast for something the screen already shows; a success toast before the server confirmed; raw error text, codes or status strings |

### 7.3 Progress rules

1. **Determinate only for measured work**: upload (frames done of total), download bytes, stitch (the stitcher's own `PROGRESS` lines), Spark load progress.
2. **Indeterminate for estimated work**: `generating_draft`, `generating_hq` (worker pseudo-progress, `backend/src/worker.ts:176-182`). Show a time range instead: "Usually under a minute" / "Usually 5 to 10 minutes". Ignore `progress` for these statuses in the client. No backend change needed.
3. **Steps, not one global bar**: a status change advances a step. A bar never runs backwards. A new step's bar starts hidden and fades in at its first value.
4. **Slowness**: if `heartbeat_at` is older than 90 s (stitch) or 120 s (generation), add "Taking longer than usual" in `warning`. If the client's own polls are failing, show the offline banner instead and do not claim the server is slow.
5. **Spinners** only while the user is actively waiting on that screen (button busy, first load). Placeholders (`.redacted`) for content loading.
6. **Counters** use "{n} of {total}" with `.numericText()` transitions. "{n}/{total}" goes.

### 7.4 Status to copy (pill / card)

Pill = short label + symbol + color. Card = Detail (the Library card shows the pill plus the card's one-line form).

| Status | Pill | Card (Detail) | Progress | Actions |
|---|---|---|---|---|
| `capturing` | Scanning (accent) | (not normally visible) | none | none |
| `uploading`, local session on this phone | Uploading (accent, `arrow.up`) | Step 1 of 3 · Uploading photos · {n} of 28 | determinate (manifest) | none |
| `uploading`, no local session | Uploading (accent) | Waiting for the upload from your phone. | indeterminate | Delete (menu) |
| `stitching` | Building (accent) | Step 2 of 3 · Combining photos | determinate (stitch %), bar only | none |
| `generating_draft` | Building (accent) | Step 3 of 3 · Building your space. Usually under a minute. | indeterminate | none |
| `draft_ready` | Ready (success, `checkmark.circle.fill`) | (no card: actions + Improve quality card) | none | Explore, 360°, Improve quality |
| `generating_hq` | Improving (accent, `sparkles`) | Improving quality… usually 5 to 10 minutes. You can keep exploring. | indeterminate | Explore, 360° |
| `complete` | Ready (success) + "High quality" label | (no card) | none | Explore, 360° |
| `failed_upload` | Didn't upload (danger) | The upload didn't finish. If the scan is still on this phone, you can upload it again from Scan. Otherwise, delete it and scan again. | none | Delete; "Go to Scan" when a local session exists |
| `failed_stitch` | Needs attention (danger) | Couldn't combine your photos. Try again. If it fails again, scan the room again, keeping the phone over one spot. | none | **Try again**, Delete |
| `failed_generating_draft` | Needs attention (danger) | Couldn't build your space. This is usually temporary. Try again. | none | **Try again** (uses one of today's scans: say so on the button caption), Delete |
| `failed_generating_hq` | Ready (success) + "Quality upgrade failed" note (warning) | Couldn't improve quality. Your space is still here. | none | Explore, 360°, **Try again** |
| any active status + stale heartbeat | (unchanged pill) | + "Taking longer than usual" | unchanged | none |
| unknown future status | Updating (secondary) | We're updating this space. Pull to refresh. | none | none |

Pill transitions: label `.contentTransition(.interpolate)`, symbol `.contentTransition(.symbolEffect(.replace))`, color animated with `quick`. The in-progress pill shows a small dot that pulses with `phaseAnimator` (static under Reduce Motion).

**Retry UI (`POST /v1/worlds/{id}:retry`, branch `feat/backend-state-retry`)**:
- Placement: the failure card's primary button "Try again", plus "Try again" in the Library card's context menu.
- Cost honesty: for `failed_generating_draft` the button caption says "Uses 1 of today's scans" (the route charges the scan quota). For `failed_generating_hq`, open the same confirmation sheet as Improve quality (it can bill 1500 credits again).
- Not optimistic. On tap: the button shows a spinner and "Trying again…", and is disabled (double-tap safe on both client and server).
- `200 {world, job_id}`: replace the world in the shared store with the response, the pill animates to the in-progress status, polling starts, light impact haptic. No toast: the change of status is the confirmation.
- `200 {world, job_id: null}` (replay or concurrent): same as above, using the returned world.
- `409 not_retryable`: refetch the world. If the status really did not change, toast "This space can't be retried right now."
- `429` (scan quota, draft only): card note "You've used today's scans. More at {time}." with the button disabled until then. `rate_limited`: toast "Too many tries. Wait a moment and try again."
- `404`: toast "This space was deleted.", remove it from the store, pop to Library.
- Network: toast "You're offline. Check your connection and try again." The button returns to its idle state.
- Backend follow-up (not required for v1 of this UI): expose a `failure_reason` code on the world (`budget_exceeded`, `provider_error`, `bad_input`, `timeout`), so the card can say "Today's limit for quality upgrades is used up. Try again tomorrow." and avoid offering a retry that will fail again. Today `last_error` lives only on the job row.

### 7.5 Improve quality (Enhance) flow

A sheet (medium detent):

```
Improve quality
Builds a sharper, more detailed version of this space.
Takes about 5 to 10 minutes. You can keep exploring meanwhile.
Limited to one space a day for now.
( Improve quality )   Cancel
```

On confirm: POST `:enhance`, not optimistic. On `2xx`, apply the returned status (or refetch) and show the Improving card. On `409`, refetch. On `429 rate_limited`, use the toast from the error map. If the world later lands in `failed_generating_hq`: the 7.4 row (the space stays usable).

### 7.6 Full inventory of today's feedback surfaces and verdicts

| # | Surface | Trigger | Text | Accurate? | Fix |
|---|---|---|---|---|---|
| T1 | Toast (Capture) `CaptureScreenModel.swift:141` | missing plist key | Camera permission text is missing… | Accurate, developer-only | DEBUG only |
| T2 | Toast `:151` | camera declined | Camera access is needed… | Accurate, but no way forward | Banner + Open Settings |
| T3 | Toast `:154` | camera denied or restricted | Camera access is denied… | Accurate; "restricted" (parental controls) gets the same text | Banner; for restricted: "Camera access is restricted on this iPhone." |
| T4 | Toast `:177` | upload flow failed | Upload failed… (raw error) | Partly: raw error, truncated at 3 lines | Banner with cause from the error map |
| T5 | Toast `:196` | manual retry with nothing pending | Nothing left to upload. | Accurate, but a success style for a non-event | Remove |
| T6 | Toast `:200` | manual retry failed | Upload failed again — <reason> | The reason may read "Server error (0): …" (finding 5) | Typed error + map |
| T7 | Toast `:202` | retry deferred | Upload not retried — already uploading. | Error style for a non-error; "nothing to do" can show | Remove; the banner reflects state |
| T8 | Toast `:211` | discard confirmed | Scan discarded. | Accurate | "Scan deleted." |
| T9 | Toast `:224` | launch resume uploaded N | Resumed N pending scan uploads. | Shown before `frames:done`? No: after success. Accurate, but only on the Capture tab | Remove; the Library card appears |
| T10 | Toast `:231` | upload success | Scan uploaded — watch it build in Library. | Accurate, but invisible (tab switch at 0.7 s) and the Library is stale (finding 2) | Route to Detail via the shared store |
| T11 | Toast (Capture debug) `CaptureDebugToolsView.swift:108` | test scan error | raw error | Developer tool | keep |
| T12 | Toast (Library) `LibraryView.swift:176` | list load failed (manual only) | raw APIError text | Misleading next to the empty state (finding 1); hidden under the Settings sheet | Error state view / offline banner |
| T13 | Toast (Detail) `WorldDetailView.swift:270`, `:290` | button tapped with no asset | This world has no … yet. | Cannot normally fire (buttons disabled) | Hide buttons instead |
| T14 | Toast (Detail) `:307` | explorer download failed | raw | Raw text | Moves into the Explorer error overlay |
| T15 | Toast (Detail) `:320` | first fetch failed (only when no list data) | raw | Errors hidden when opened from a list | Show a stale-data note on failure |
| T16 | Toast (Detail) `:348` | enhance accepted | Enhancing to HQ — this takes a few minutes. | Accurate at that moment; may fail later on budget (finding 6) | Status card instead |
| T17 | Toast (Detail) `:352`, `:363` | enhance or delete failed | raw APIError | 429 copy wrong (finding 5) | Error map |
| T18 | Toast (Settings) `SettingsView.swift:239` | cache cleared | Cache cleared. | Accurate | "Downloads cleared" |
| T19 | Toast (Settings) `:254` | account delete failed | raw | Raw | Error map |
| T20 | Toast (Pano) `PanoPreviewView.swift:123`, `:125` | save result | Couldn't save: <raw> / Saved to Photos. | Accurate; no Settings path | Alert on denied |
| D1 | confirmationDialog Detail `:99-110` | Delete | Delete this world?… | Accurate; no success feedback after; Library stale | Toast after a 2xx + store removal |
| D2 | confirmationDialog Start `CaptureStartView.swift:104-115` | Discard scan | Discard this scan?… | Accurate | Copy |
| D3 | confirmationDialog HUD `CaptureHUDView.swift:58-67` | Close | Abandon this scan?… | Accurate | Copy |
| D4 | 2x confirmationDialog Settings `:182-201` | Delete account | … | Accurate, but destructive for all installs under dev auth (R24) | Hide under dev auth |
| B1 | Coaching banners `CoachingLayer.swift` | tracking, thermal, drift, exposure | (see deck) | Accurate; priority logic sound | Copy; warning haptic on hard drift |
| B2 | Low-light / lost-track cards `CaptureHUDView.swift:311-359` | engine flags | (see deck) | Accurate, self-clearing | Copy; 44 pt buttons |
| B3 | Thermal overlay `CaptureView.swift:127-160` | critical thermal | (see deck) | Accurate | Copy |
| B4 | Quota notice / low-quota hint `CaptureStartView.swift:42-50`, `:119-134` | `GET /v1/me/quota` | (see deck) | Accurate; fails open when unknown (good) | Copy; emoji removed |
| B5 | Parked-upload notice `:80-103` | pending summary | (see deck) | Accurate | Copy |
| B6 | Capture failure text `:35-41` | engine `.failed(message)` | raw engine message | Raw (e.g. "Couldn't create a capture folder: <error>") | Map to "Something went wrong starting the scan. Try again." + log detail |
| P1 | Upload ring `UploadOverlayView.swift` | upload flow | n/28 | Sticks at 28/28 during depth + `frames:done` | "Finishing up…" |
| P2 | Library upload bar `LibraryView.swift:241-249` | manifest progress | Uploading n/28 | Accurate (client truth) | Copy |
| P3 | Library / Detail progress bar + % `:330-349` | `world.progress` | n% | **Inaccurate for generation** (pseudo); resets between phases | Section 7.3 |
| P4 | Heartbeat captions `:351-358` | `heartbeat_at` | working · updated… / Taking longer… | Jargon; misfires on queue and offline | Section 7.3 rule 4 |
| P5 | Status chip spinner `:368-372` | `isActive` | label | Accurate except failed HQ severity | Section 7.4 |
| P6 | Detail timeline `WorldDetailView.swift:372-495` | status | 6 phases | Implies draft_ready is incomplete; failed raw label | 3-step list only while building |
| P7 | Detail explore button progress `:207-214` | SplatCache download | Preparing… n% | Accurate bytes, but followed by a second bar | Move into the Explorer |
| P8 | Explorer ring `ExplorerView.swift:129-160` | download / Spark progress | Preparing your world… / Rendering splats | Accurate values; jargon; no termination path | Section 4.7 |
| P9 | Pano ring `PanoPreviewView.swift:135-147` | download | Loading 360° photo… | Accurate | Reduce Motion |
| P10 | Thumbnail `ProgressView()` `LibraryView.swift:282`, `WorldDetailView.swift:132` | AsyncImage loading | none | Accurate | Placeholder fill, no spinner |
| P11 | Start: "Starting camera…" `CaptureView.swift:58-64` | engine starting | | Accurate | keep |
| P12 | Settings busy spinners `SettingsView.swift:109`, `:171` | clear / delete | | Accurate | keep |
| H1 | Shot haptic `ShotPipeline.swift:190-194` | shot saved | medium impact | Fires after the save succeeds: accurate | keep |
| H2 | Celebration haptic `:197-201`, `CaptureEngine.swift:586` | sweep end, finish | success | Accurate | keep |
| L1 | DebugLogView states | read logs | | Accurate | keep |

---

## 8. Settings

```
Settings                                   Done
HOW TO SCAN
  How to scan                          >   (onboarding pages 2-4)
STORAGE
  3D spaces                        48 MB
  360° photos                      12 MB
  Clear downloads                          (normal tint; disabled when 0)
  footer: Downloaded copies of your spaces...
ABOUT
  Terms of use                         >   (onboarding page 5, read-only)
  Privacy                              >   (short page, no location claim)
  Acknowledgements                     >   3D spaces are generated using World Labs.
  Version                     1.0 (12)
DEVELOPER                                  (DEBUG only)
  User id, Preview fixture 360° photo, Debug logs, Replay onboarding, Reset first-scan coaching
ACCOUNT                                    (hidden under dev auth, R24)
  Delete account
```

Remove: the dev user id row in Release, the long privacy paragraph, the double confirmation (one destructive dialog is enough, as in the HIG), and the destructive tint on Clear. After a successful account deletion (when it ships), the shared store clears, the Library shows its empty state, and the app returns to onboarding.

---

## 9. Animation and interaction list

Each item is cheap (built-in SwiftUI), purposeful, and has a Reduce Motion fallback (RM).

1. **Library first load**: placeholder cards crossfade to real cards (`standard`). RM: same, opacity only.
2. **Card insert / remove**: `.transition(.opacity.combined(with: .scale(0.97)))` with `.animation(.smooth, value: ids)`. A new space appears at the top. RM: opacity.
3. **Status pill change**: interpolated text, symbol replace, color `quick` (section 7.4). RM: no symbol effect.
4. **Step list advance** (Detail): the finished step's spinner becomes a check with `drawOn`, the next row brightens (`standard`). RM: instant swap.
5. **Target lock-on**: the existing reticle snap spring (`CaptureHUDView.swift:216-217`) plus a `.selection` haptic once per target. RM: color change only.
6. **Shot confirmation**: section 4.3 (check draw-on in the reticle, facet fill, medium impact, soft 120 ms flash). RM: no flash, no scale; haptic kept.
7. **Space-ready moment** (status becomes `draft_ready` while Detail or the Library is visible and the app is active, once per space): the hero placeholder crossfades to the thumbnail with a blur from 12 to 0 over 0.6 s, the pill becomes Ready with a check draw-on, the Explore button fades in, and a `.success` haptic plays (Detail only). The Library card gets the crossfade with no haptic. RM: crossfade only.
8. **Scan complete to upload**: the bottom capsule's sphere fills completely, then the upload overlay fades in (`standard`). An optional later polish: `matchedGeometryEffect` from the sphere to the upload ring.
9. **Toast**: in from the top with opacity (`quick`), out with `exit`. RM: opacity.
10. **Onboarding**: paged `TabView` swipe (system); each page's symbol plays one `symbolEffect` on appear (`drawOn` / `.bounce`). RM: static symbols.
11. **Retry / Improve accepted**: the button label crossfades to a spinner, then the card swaps to the in-progress state (`standard`) with a light impact.
12. **Explorer coach and 360° hint**: fade out on the first drag (`exit`).
13. **Upload counter**: `.contentTransition(.numericText())` on "n of 28" (already in `UploadOverlayView.swift:42`).

Explicitly not doing: parallax headers, looping background gradients, confetti, custom page transitions, `matchedGeometryEffect` from Library card to Detail (the push transition is system; the iOS 26 zoom transition `navigationTransition(.zoom)` is an option later).

---

## 10. Accessibility checklist (applies to every work package)

- Dynamic Type: text styles only; card titles wrap to 2 lines; meta rows become a `ViewThatFits` (HStack, else VStack) at accessibility sizes; HUD clamped at `.accessibility2`.
- VoiceOver: labels on every icon button (Explorer close, 360° close and save, Settings gear, HUD close); cards combined into one element with a status label; the step list says "done / in progress / not started"; shot and upload progress announced; toasts announced.
- Contrast: no `.tertiary` for text; the accent token meets 4.5:1 in both appearances; white text over camera always sits on a glass capsule or scrim.
- Targets: 44 pt minimum: `CaptureHUDView.swift:238` (38), `ExplorerView.swift:228` (40), `PanoPreviewView.swift:220` (40).
- Motion: section 2.4 Reduce Motion rules; the white flash removed under Reduce Motion and lowered for everyone.
- Color is never the only signal: pills carry a word and a symbol; the pivot indicator keeps its accessibility label (`PivotIndicatorView.swift:41-42`).

---

## 11. Implementation plan

Order: WP1 first (shared foundation, small). WP2 to WP5 then run in parallel: each owns a disjoint set of files. Every WP: Swift 6, no new dependencies, unit tests where logic exists, sim runs only against a local mock (`VIRTSPACE_API_BASE_URL`, CLAUDE.md agent-isolation rules), no emoji, copy exactly as in section 6.

Coordination: branch `fix/ios-robustness` (R25) also edits `Core/API/APIError.swift` and `Core/Capture/CaptureUploader.swift`. Rebase WP1 and WP4 on it once it merges. `:retry` comes from `feat/backend-state-retry`. Changes to `project.pbxproj` (permission strings) must wait for the owner's uncommitted Xcode 27 project changes.

### WP1: Foundation (tokens, feedback, errors, routing, shared store)
Files: new `Core/UI/Theme.swift`, new `Core/UI/ToastCenter.swift` (replaces `Core/UI/ToastModifier.swift`), new `Core/UI/WorldStatus+Presentation.swift` (move presentation out of `Core/Models/Models.swift:64-116`), `Core/API/APIError.swift`, `Core/API/APIClient.swift` (error-code parsing, `retry(worldId:)`, pagination params), new `Core/Data/WorldStore.swift`, new `Core/App/AppRouter.swift`.
Scope: tokens (section 2); ToastCenter with a passthrough-window host (7.1); typed errors that parse the `error` code (`rateLimited`, `scanQuota(resetAt)`, `notFound`, `notRetryable`, `offline`, `server`) with the user copy from section 6; a `.localState(String)` case in place of `server(0, …)`; status presentation per section 7.4 (pill label, symbol, tone, step index, `isProgressMeasured`); `WorldStore` (`@Observable`, app-scoped list + by-id cache, pagination, a single poll loop while any world is active **and** the scene is active, `insert`, `remove`, `replace(from:)`, `consecutiveFailures`); `AppRouter` (`selectedTab`, `libraryPath`, `open(worldId:)`).
Acceptance:
- Unit tests: every backend error code maps to the right case and copy (`rate_limited` is not quota; 401 has no "Secrets" text in Release).
- Every `WorldStatus`, including each `failed_*` and an unknown string, has non-empty pill copy and never shows a raw status string.
- `isProgressMeasured` is false for `generating_*`.
- A toast shown while a sheet is presented is visible above it (manual check); dedupe test.
- The store's poll loop stops when nothing is active and when the scene goes inactive.

### WP2: Library and Space detail
Files: `Features/Library/LibraryView.swift`, `Features/Library/WorldDetailView.swift` (split the timeline and status card into `Features/Library/StatusCard.swift`; this also reduces R35's god object), `ContentView.swift` limited to wiring the store and router into the Library stack.
Scope: sections 4.5 and 4.6, 7.3 to 7.5, retry UI, Improve sheet, delete flow, ready moment (9.1 to 9.4, 9.7, 9.11), pagination, accessibility.
Acceptance:
- Against the mock backend: a failed first load shows the error state, never "No spaces yet"; an empty list shows the empty state.
- A world created through the store appears in the Library without pull to refresh. A deleted world disappears from the list after the server's 2xx, and a "Space deleted" toast shows.
- No percentage shown for `generating_*`; no bar ever moves backwards across a status change.
- `failed_generating_hq` shows Ready + the note, Explore enabled, Try again present. Each `failed_*` retries via `:retry` and handles 200 (both `job_id` forms), 409, 429, 404 and offline per 7.4.
- More than 20 worlds paginate.
- Offline banner after 2 failed polls; no "taking longer" text while offline.
- VoiceOver reads each card as one element with its status.

### WP3: Onboarding, consent and app shell
Files: new `Features/Onboarding/OnboardingView.swift`, `Features/Onboarding/TermsView.swift`, `Features/Onboarding/OnboardingStore.swift` (consent version + flags), `ContentView.swift` (tabs, order, `@SceneStorage`, onboarding cover, appearance), `VirtSpaceApp.swift` (toast window install), a defensive consent check in `Core/Capture/UploadManager.swift` (a single guard at the kick entry points).
Scope: section 3, section 5 pages 1 to 5, Settings entry points exposed as views for WP5.
Acceptance:
- A fresh install shows onboarding; "Skip" skips to Terms; Terms cannot be dismissed without "Agree and continue".
- No upload starts without current consent (unit test on the guard).
- Bumping `currentTermsVersion` shows only the terms page.
- A returning user never sees onboarding.
- The last-used tab is restored.
- The app follows the system appearance outside Scan / Explorer / 360°.
- Onboarding passes at the largest accessibility text size without clipping.

### WP4: Scan flow (start, HUD, coaching, upload overlay)
Files: `Features/Capture/CaptureStartView.swift`, `Features/Capture/CaptureView.swift`, `Features/Capture/CaptureScreenModel.swift`, `Features/Capture/HUD/CaptureHUDView.swift`, `HUD/CoachingLayer.swift`, `HUD/UploadOverlayView.swift`, `HUD/ProgressSphereView.swift` (counter text only), the warning strings in `Features/Capture/Engine/ARKitCaptureSource.swift:305-320`, the failed-shot string in `Engine/ShotPipeline.swift:131`, new `Features/Capture/FirstScanCoach.swift`, `Features/Capture/CaptureDebugToolsView.swift` (disclosure group). Capture engine logic is not touched.
Scope: sections 4.2 to 4.4, camera priming (5.6), first-scan coaching (5.7), the direction line, haptics (lock-on, hard drift), the shot-confirmation animation, VoiceOver announcements, routing to Detail via `AppRouter` after upload success.
Acceptance:
- Quota spent: the button reads "Scan unavailable today". Camera denied: the banner with Open Settings works.
- The upload overlay shows "Finishing up…" after the last frame. On success the app lands on the new space's Detail. On failure the banner (not a toast) shows a mapped cause.
- No target labels ("Horizon 3") visible.
- Reduce Motion removes the flash.
- Sim run with `SimulatedCaptureSource` (mock backend only) completes 28 shots with coaching on the first run only.
- Existing capture unit tests stay green (80/80 baseline).

### WP5: Viewers and Settings
Files: `Features/Explorer/ExplorerView.swift`, `Resources/SparkViewer/viewer.html` (joystick ARIA label and stick frame message only), `Features/Preview/PanoPreviewView.swift`, `Features/Settings/SettingsView.swift`, the permission strings in the build settings (after owner coordination).
Scope: sections 4.7, 4.8 and 8; the Explorer owns download + render (`.remote`) with labelled steps; a process-termination handler; 44 pt glass controls with labels; Photos-denied alert; 360° opens at longitude 0; Settings restructure; dev id and Delete account hidden under dev auth; location string and privacy claim removed.
Acceptance:
- Opening a space shows one loading screen with two labelled steps. Killing the WebContent process (`webView._killWebContentProcess` in DEBUG, or the Web Inspector) shows "This space closed unexpectedly" with a working Reload.
- All icon buttons have VoiceOver labels and 44 pt targets.
- The Settings Release build shows no user id or Delete account row while `AUTH_MODE` is dev.
- "Clear downloads" toast and sizes update.
- No user-facing "splat", "pano", "world" or "HQ" string remains (grep check over `Features/` outside `Debug/` and DEBUG blocks).

Dependency note: WP2 changes Detail to present the Explorer with `.remote`; WP5 makes that path the full loading experience. Either can land first; the only link is the existing `SplatSource.remote` enum case.
