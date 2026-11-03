# File preview in chat

## Overview

When the agent references a file that lives on the agent host — a markdown link to an absolute
path, a `MEDIA:/path` tag, or a bare `/home/eugene/out/report.pdf` in prose — the reference
becomes a tappable link in the transcript, and tapping it opens a modal **file preview sheet**.
Images, text files and PDFs get a real preview. Everything else gets a generic card with the
file's name, full path, size and a one-line reason. Every kind offers **Copy path** and
**Share** (the bytes are downloaded to a temp file and handed to the iOS share sheet, so a
`.docx` or `.zip` can go to Files, Pages, AirDrop or Mail).

Problem it solves: today the phone shows those references as inert text. The agent produces
reports, screenshots, exports and logs constantly, and the only way to see them is to walk
over to the host. The web dashboard has the same gap; the Electron desktop solves it with a
preview pane and `/api/fs/*` routes, which the gateway already exposes to every surface.

Integration: a pure scanner in HermesKit marks file references; both prose renderers attach a
custom `hermes-file:` URL to those ranges; one `openURL` hook in `ChatView` routes the tap into
`ChatFeature`; a new `@Presents` child `FilePreviewFeature` owns loading, type resolution, copy
and share over a new `FilePreviewClient`. No inline images, no attachment chips, no change to
transcript row identity, no change to `session.create`.

Design history: brainstorm on 2026-11-03 (this plan). Desktop reference lives in the sibling
clone `/Users/eugene/Documents/Development/Personal/hermes-agent`, read via
`git show upstream/main:<path>` (verified at `c314285f07`; the working tree goes stale).

## Context (from discovery)

**Server (upstream/main `hermes_cli/web_routers/files.py`, mounted unconditionally by
`web_server.py` — present on every surface, no capability flag, no JSON-RPC read method):**

| Route | Returns | Limit |
|---|---|---|
| `GET /api/fs/read-text?path=&session_id=` | `{binary, byteSize, language, mimeType, path, text, truncated}` | reads the first 512 KB |
| `GET /api/fs/read-data-url?path=&session_id=` | `{dataUrl: "data:<mime>;base64,…"}` | 16 MB (413 above) |
| `GET /api/fs/download?path=&session_id=` | `FileResponse` attachment, raw bytes | none |

- Auth is the same header `RequestAuth` already writes (`X-Hermes-Session-Token` or
  `Authorization: Bearer`); cookie mode passes via the jar. No query-string token on these
  routes.
- `path` may be absolute, `~/…`, or a `file://` URL. With `session_id` a relative path resolves
  against the session cwd and `/workspace/...` sandbox paths map to the host. Sensitive files
  (`.env*`, `auth.json`, `config.yaml`, credential files) → 403. Missing → 404 whose `detail`
  may mention the sandbox.
- `read-text` decides text-vs-binary server-side (null bytes / control-character ratio).
- Message events and history rows carry **no structured attachment field**; detection is text
  parsing, exactly as on desktop.
- Desktop reference: `apps/desktop/src/lib/markdown-preprocess.ts` (`FILE_LINK_RE`,
  `routeFileLinksToPreview`), `lib/chat-messages/parts.ts:192-290` (`MEDIA:` tags →
  links), `components/chat/preview-attachment.tsx` (the card), `app/chat/right-rail/preview-file.tsx`
  (the pane). Desktop does **not** linkify bare paths or relative paths; this plan adds bare
  absolute paths because the phone's sessions get the TUI prompt, which tells the model to state
  plain paths rather than `MEDIA:` tags.

**Mobile (this repo):**
- `HermesMobile/Sources/Features/Chat/SelectableText.swift` — `ProseAttributedBuilder.make`
  (~L47) builds the `UITextView` string line by line; `inlineRuns` (~L76) attaches `run.link`
  from the inline markdown parse. The `UITextView` has no delegate: a tap on any link falls to
  the system default today (a `file://` link does nothing).
- `HermesMobile/Sources/Features/Chat/MarkdownText.swift` — `inline(_:)` (~L102) is the
  SwiftUI `Text` path for blockquotes, list items and table cells; prose goes through
  `ProseAttributedBuilder` (~L61).
- `HermesMobile/Sources/Features/Chat/ChatView.swift` — `.sheet(item: toolDetailBinding)` and
  `.sheet(isPresented: modelPickerBinding)` (~L117–134) are the existing chat sheets;
  `CollectionTranscriptView(... cell: transcriptCell)` (~L193) is the cell builder closure.
- `HermesMobile/Sources/Features/Chat/Transcript/CollectionTranscriptView.swift` ~L302 —
  `UIHostingConfiguration { builder(row) }`: each cell is its own SwiftUI hierarchy, so the
  SwiftUI environment of `ChatView` does **not** reach it; anything a cell needs must be set
  inside the builder.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `modelPicker: ModelPicker?`
  (~L169) + `modelPickerDismissed` (~L951, ~L2296) is the existing plain-optional sheet idiom;
  `CancelID` (~L1079); `copiedFeedbackDuration = .seconds(1.5)` (~L1096) + `rowCopyToken` is
  the copy-toast idiom; `connection: ServerConnection` (L34); `liveSessionID` / `storedSessionID`
  (~L426) with `sessionKey = storedSessionID ?? liveSessionID` (~L510).
- `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` — `makeURL` (L728), `get`
  (L738), `validate` (L768, maps status → `RESTError`), `serverDetail` (L782),
  `RequestAuth.apply` (L91), `resolveAuth(for:session:tokenStore:)` (L634), `live(session:
  tokenStore:)` (L315) — the pattern every new client call must follow (bearer via
  `BearerTokenStore.validAccessToken()`).
- `HermesKit/Sources/HermesKit/Clients/PasteboardClient.swift` — copy goes through here.
- Tests: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift` has `MockURLProtocol`
  (offline REST tests); `ChatRowCopyTests.swift` is the small-model test style;
  `HermesMobileTests/SnapshotTestSupport.swift` has `componentImage` / `deviceImage`;
  `MarkdownTableLayoutTests.swift` is the measured `UIWindow` XCTest style.
- `Project.swift` globs `HermesMobile/Sources/**` and `HermesMobileTests/**` — new files need
  `tuist generate` before `xcodebuild` sees them.

## Development Approach

- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; commit at each task completion
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - unit tests for new/modified functions; success and error scenarios
  - HermesKit logic → `swift test` (`script -q /dev/null swift test --package-path HermesKit`
    or `make test`); app views → `make snapshot` (new snapshot: run twice — first records and
    fails by design, second asserts clean)
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- keep view files declarative; every decision that can be unit-tested lives in HermesKit
- commit messages: capitalized verb, no conventional-commit prefixes

## Testing Strategy

- **unit tests (HermesKit, Swift Testing)**: scanner grammar incl. a false-positive corpus; URL
  round-trip; `FilePreviewClient` over `MockURLProtocol` (auth header, query items, status
  mapping, data-URL decode, temp-file download + progress); `FilePreviewFeature` `TestStore`
  per content outcome, share lifecycle, copy toast; `ChatFeature` tap / double-tap / dismiss
  cleanup / `ifLet` cancellation.
- **snapshot tests (HermesMobileTests)**: a message bubble containing a bare path (link
  styling); the sheet in generic, text (truncated), error, image and PDF states; both
  appearances where the existing suite does so. Scrollable views pin width **and** height.
- **measured layout test**: the text preview's `contentSize.height > bounds.height` for a long
  fixture in a hosted `UIWindow`, `.dynamicTypeSize(.large)` pinned.
- no e2e suite exists in this project.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

```
assistant text ──► FileReferenceScanner.segments(line)   (HermesKit, pure)
                      │  .text / .file(display, path)
                      ▼
   ProseAttributedBuilder (UITextView)   MarkdownText.inline (SwiftUI Text)
          attach .link = hermes-file://preview?path=…
                      │ tap
                      ▼
   SelectableText coordinator ─► context.environment.openURL(url)
   SwiftUI Text ────────────────► openURL(url)
                      │
   ChatView OpenURLAction (installed on cell builder content + chat body)
     hermes-file:  → store.send(.fileReferenceTapped(path:)) → .handled
     anything else → .systemAction (https keeps opening Safari)
                      │
   ChatFeature  @Presents var filePreview: FilePreviewFeature.State?   (.ifLet)
                      │
   FilePreviewFeature ──► FilePreviewClient (readText / readDataURL / download / removeTemp)
                      │
   ChatView .sheet(item:) ─► FilePreviewSheet (generic | text | image | pdf | error)
                              toolbar: Copy path · Share (download → UIActivityViewController)
```

Key decisions and rationale:
- **Detection = desktop's two shapes + bare absolute paths with an extension.** Bare paths are
  the common case on the phone (TUI prompt). The extension requirement and filename-safe
  character class keep false positives down; the generic card makes a residual false positive
  harmless. Relative paths, bare paths with spaces and extension-less paths are not linked.
- **Tappable in place, not chips or inline images.** Row heights stay deterministic, nothing
  loads until tapped, no new row kind, no snapshot churn. Inline images are a possible later
  feature.
- **One `openURL` hook.** Both renderers end in SwiftUI's `openURL`; cells don't inherit
  `ChatView`'s environment, so the action is installed inside the cell builder. No closure is
  threaded through `MessageBubbleView`.
- **First `@Presents` child in `ChatFeature`, deliberately.** Dismissing the sheet must cancel
  an in-flight read or a multi-megabyte download; `.ifLet` auto-cancellation gives that, in the
  spirit of the "nil-out is mandatory" rule the live-chat slot already follows.
- **Server decides text vs binary.** Only images and PDFs are chosen by extension (they need the
  data-URL route); every other extension asks `read-text`, whose `binary` flag picks text view
  vs generic card. No client-side MIME table beyond image/PDF extensions.
- **No `*Supported` capability flip** for `/api/fs/*`. The routes are mounted unconditionally on
  current agents; on a very old agent the link is harmless and the generic card ("not found on
  the agent") is already the degraded state. Documented as a deliberate exception to the
  capability-gating rule.
- **`session.create` is unchanged** — no `source: "desktop"`. That would switch the model to the
  desktop prompt and make it assume desktop-only widgets.
- **Share = `/api/fs/download` streamed to a temp file, no client cap**, determinate progress
  from `Content-Length`, cancellable, deleted when the preview is dismissed.

## Technical Details

### Detection grammar (`FileReferenceScanner`)

Input: one prose line (both renderers already work line by line; paths never span lines).
Output: `[InlineFileSegment]` = `.text(String)` | `.file(display: String, path: String)`.
Scanning order; earlier matches claim their ranges:

1. **Markdown link targets** — handled where the inline markdown parse produced `run.link`:
   `FileReference.path(fromLinkTarget: URL) -> String?` returns a path when the URL's scheme is
   `file` (percent-decoded path; `file://localhost/...` and `file:///...` both accepted) or when
   it has no scheme and its string starts with `/` or `~/`. The label is kept as display text.
   Anything else (`https:`, `mailto:`, anchors) returns nil and is left untouched.
2. **`MEDIA:` tags** — `MEDIA:` immediately followed by either a double-quoted path (may contain
   spaces) or a run of non-whitespace characters. Display text = last path component.
3. **Bare paths** — regex, applied to the remaining plain and code-span text:
   `(?<![\w/~.])(?:~|)(?:/[A-Za-z0-9._\-+@%~]+)+/[A-Za-z0-9._\-+@%~]*\.[A-Za-z0-9]{1,10}` — i.e.
   a `/` or `~/` root at a non-word boundary, one or more filename-safe segments, and a final
   segment with a 1–10 character extension. Then trim trailing `.,;:)]}'"` and backticks (the
   next character after the match may legitimately be sentence punctuation). Display text = the
   matched path. Must **not** match: `https://x/y.z` (the `//` is preceded by `:`; the
   lookbehind plus the required leading `/` boundary rule it out), `1/2/2026`, `3/4`,
   `./out/x.pdf`, `src/foo.swift`, `/tmp`, `/usr/bin/python`, `a/b.c`.

`hermes-file:` URL: `FileReference.url(for path: String) -> URL` →
`hermes-file://preview?path=<percent-encoded>`; `FileReference.path(from: URL) -> String?`
inverts it and returns nil for any other scheme/host. Round-trips arbitrary paths incl. spaces,
`~`, unicode and `%`.

### `FilePreviewKind` (pure, HermesKit)

`static func infer(path:) -> FilePreviewKind` by lowercase extension:
`.image` ∈ {png, jpg, jpeg, gif, webp, heic, heif, bmp, tiff, tif}; `.pdf` ∈ {pdf}; else
`.other`. `displayName` = last path component; `symbolName` = SF Symbol by kind/extension
(`photo`, `doc.richtext`, `doc.text`, `tablecells`, `doc.zipper`, `doc`).

### `FilePreviewClient` (`@DependencyClient`, HermesKit/Clients)

```swift
struct FileTextRead: Decodable, Equatable { binary: Bool; byteSize: Int?; language: String?;
                                           mimeType: String?; text: String; truncated: Bool }
struct FileDataRead: Equatable { mimeType: String?; data: Data }   // decoded from dataUrl

var readText:    (ServerConnection, _ path: String, _ sessionID: String?) async throws -> FileTextRead
var readData:    (ServerConnection, _ path: String, _ sessionID: String?) async throws -> FileDataRead
var download:    (ServerConnection, _ path: String, _ sessionID: String?, _ fileName: String)
                   -> AsyncThrowingStream<DownloadEvent, Error>   // .progress(Double?) … .finished(URL)
var removeTemp:  (URL) async -> Void
```

- Live: `makeURL(base, "/api/fs/read-text", query: [path, session_id?])`, auth via
  `resolveAuth(for:session:tokenStore:)`, `validate(_:data:)` for status mapping (404 →
  `RESTError.notFound`, others `.server(status:detail:)` with `serverDetail`). Data URL parsed
  with a small pure `DataURL.parse(_:) -> (mime, Data)?` (HermesKit, unit-tested).
- `download` streams `session.bytes(for:)` into
  `temporaryDirectory/hermes-file-preview/<UUID>/<fileName>` (the directory keeps the real
  filename for the share sheet), yielding `.progress(received / contentLength)` (nil fraction
  when `Content-Length` is absent) every ≥64 KB, then `.finished(url)`. Cancellation deletes the
  partial directory.
- `testValue`: unimplemented (default `@DependencyClient` behaviour) so a reducer test fails
  loudly if it hits an endpoint it didn't stub.
- Live value guarded for non-UIKit only where needed; the client is plain `URLSession`, so it
  stays fully testable on macOS.

### `FilePreviewFeature` (HermesKit/Features)

```swift
State: path, fileName, kind: FilePreviewKind, sessionID: String?, connection: ServerConnection,
       content: Content = .loading, share: ShareState = .idle, copiedToken: Int? = nil
Content: .loading | .text(FileTextRead) | .image(Data) | .pdf(Data)
         | .generic(GenericInfo{ reason: Reason, byteSize: Int?, serverDetail: String? })
         | .failed(message: String)
Reason: .unsupported | .tooLarge | .notFound | .protected
ShareState: .idle | .downloading(fraction: Double?) | .ready(URL)
Actions: task, retry, loaded(Result<Loaded, RESTError>), copyPath, copiedFeedbackElapsed,
         shareTapped, cancelDownload, downloadEvent(DownloadEvent), downloadFailed(String),
         shareDismissed
```

Load algorithm on `.task` / `.retry`: `.image`/`.pdf` → `readData`; success → `.image(data)`
(if `UIImage` can't decode it the **view** shows the generic card — the reducer stays
platform-free, so decodability is checked view-side with an `onAppear`-free static helper) /
`.pdf(data)`; `.other` → `readText`; `binary == false` → `.text`, else
`.generic(.unsupported, byteSize)`. Error mapping (both routes): `.notFound` →
`.generic(.notFound, serverDetail)`; `.server(403)` → `.generic(.protected)`; `.server(413)` →
`.generic(.tooLarge)`; anything else → `.failed(error.message)` with Retry. Nothing is
swallowed.

Share: `.shareTapped` → `share = .downloading(nil)`, effect runs `download` under
`CancelID.download`; `.downloadEvent(.progress)` updates the fraction; `.finished(url)` →
`.ready(url)`; `.downloadFailed` → `share = .idle` + `content` untouched + an inline share error
string (`shareError: String?`) shown as a banner in the sheet; `.cancelDownload` cancels the
effect and returns to `.idle`; `.shareDismissed` → `.idle` (temp file kept until the preview is
dismissed, so a second Share is instant). Copy path: `pasteboard.copy(path)`, bump
`copiedToken`, `copiedFeedbackDuration` dwell under `CancelID.copyFeedback` (`cancelInFlight`),
`copiedFeedbackElapsed` → nil.

### `ChatFeature` wiring

- `@Presents public var filePreview: FilePreviewFeature.State?`
- `case fileReferenceTapped(path: String)`, `case filePreview(PresentationAction<FilePreviewFeature.Action>)`
- `.fileReferenceTapped`: no-op if `filePreview != nil`; else
  `filePreview = .init(path:, sessionID: state.sessionKey, connection: state.connection)`.
- `.filePreview(.dismiss)`: if the child had `share == .ready(url)` (or a partial download dir),
  run `filePreviewClient.removeTemp(url)` fire-and-forget, then let `.ifLet` nil the state.
- `.ifLet(\.$filePreview, action: \.filePreview) { FilePreviewFeature() }`.
- Slot teardown already nils chat state wholesale, which takes the sheet and its effects down.

### Views (`HermesMobile/Sources/Features/Chat/FilePreview/`)

- `FilePreviewSheet(store:)` — `NavigationStack`; title = `fileName`; `Done` (dismiss);
  bottom toolbar `Copy path` + `Share`; body switches on `content`; a thin progress bar with
  Cancel overlays the bottom while `share == .downloading`; `.sheet(item: shareURL)` presents
  `ActivityShareSheet` (a `UIActivityViewController` representable) whose completion sends
  `.shareDismissed`; the copy toast reuses the existing overlay idiom off `copiedToken`.
- `GenericFileCardView` — SF Symbol, filename, full path (centered, selectable), byte size via
  `ByteCountFormatter`, reason line, optional server detail.
- `MonospacedFileTextView` — `UITextView` representable, scrollable + selectable, monospaced
  body font with Dynamic Type; caption row with `language` and a "Showing first 512 KB" banner
  when `truncated`.
- `ZoomableImageView` — `UIScrollView` representable with `UIImageView`, zoom 1–4×, double-tap
  to toggle, centers the image.
- `PDFKitView` — `PDFKit.PDFView` representable, `autoScales`, continuous vertical.
- `ChatView`: `.sheet(item: $store.scope(state: \.filePreview, action: \.filePreview))` with
  `.presentationDetents([.large])`; the `OpenURLAction` is one private `let` applied to
  `transcriptCell`'s content and to the chat body.
- `SelectableText`: a `Coordinator: NSObject, UITextViewDelegate` implementing
  `textView(_:primaryActionFor:defaultAction:)` (for a `hermes-file:` URL → `UIAction` that
  calls `context.environment.openURL(url)`; otherwise `defaultAction`) and
  `textView(_:menuConfigurationFor:defaultMenu:)` (nil for `hermes-file:`).

## Implementation Steps

### Task 1: `FileReference` model and scanner

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/FileReference.swift`
- Create: `HermesKit/Tests/HermesKitTests/FileReferenceScannerTests.swift`

- [x] add `InlineFileSegment` (`.text` / `.file(display:path:)`), `FileReference.url(for:)`,
      `FileReference.path(from:)`, `FileReference.path(fromLinkTarget:)` in `FileReference.swift`
- [x] implement `FileReferenceScanner.segments(_ line: String) -> [InlineFileSegment]` with the
      `MEDIA:` tag pass (quoted + unquoted, display = last component) and the bare-path regex
      pass incl. trailing-punctuation trimming, per the grammar in Technical Details
- [x] add `FilePreviewKind.infer(path:)`, `displayName`, `symbolName`
- [x] write table-driven tests for positives: `/home/e/out/report.pdf`, `~/Downloads/x.png`,
      backticked path, path followed by `.`/`,`/`)`, two paths in one line, `MEDIA:/a/b.mp3`,
      `MEDIA:"/a/with space.pdf"`, `+`/`@`/`%` in segments, 10-char extension
- [x] write the false-positive corpus: `https://host/a/b.pdf`, `1/2/2026`, `3/4`, `./out/x.pdf`,
      `src/foo.swift`, `/tmp`, `/usr/bin/python`, `a/b.c`, `/x/y.toolongextension`, a 11-char
      extension, mid-word `foo/bar.txt`
- [x] write tests for `path(fromLinkTarget:)` (`file:///a b.pdf` → `/a b.pdf`, `/abs/x.md`,
      `~/x.md`, `https://…` → nil, `mailto:` → nil) and URL round-trip (spaces, `~`, unicode, `%`,
      `?`/`#` in path; foreign scheme → nil)
- [x] write tests for `FilePreviewKind.infer` (case-insensitive extensions, no extension → other)
- [x] run `swift test` — must pass before task 2
- ➕ grammar refinements made while implementing (both reflected in `barePathPattern`'s doc
  comment and the test corpus): a `~` root needs no directory segment (`~/x.md` links;
  `/report.pdf` still does not), and the extension carries a `(?!\w|\.\w)` lookahead so
  `/x/y.toolongextension` cannot match its first ten letters and `/x/y.z.longext` cannot match
  `/x/y.z`, while `/a/b.pdf.` (sentence period) still ends cleanly. A bare `MEDIA:` capture
  also sheds trailing sentence punctuation and must be a plausible path (desktop parity;
  `MEDIA:...` stays prose).

### Task 2: `FilePreviewClient` over the `/api/fs/*` routes

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/FilePreviewClient.swift`
- Create: `HermesKit/Sources/HermesKit/Models/DataURL.swift`
- Create: `HermesKit/Tests/HermesKitTests/FilePreviewClientTests.swift`
- Create: `HermesKit/Tests/HermesKitTests/DataURLTests.swift`

- [x] add `DataURL.parse(_:) -> (mimeType: String?, data: Data)?` (base64 only; rejects
      non-base64 and malformed headers)
- [x] add `FileTextRead`, `FileDataRead`, `DownloadEvent` and the `@DependencyClient`
      `FilePreviewClient` (`readText`, `readData`, `download`, `removeTemp`) with `testValue`
      and `DependencyValues.filePreview`
- [x] implement `live(session:tokenStore:)` mirroring `HermesRESTClient.live`: `makeURL` +
      `path`/`session_id` query items (omit `session_id` when nil), `resolveAuth`, `validate`,
      `serverDetail`; `readData` decodes the `dataUrl` via `DataURL.parse` (malformed →
      `RESTError.decoding`)
- [x] implement `download` streaming to `temporaryDirectory/hermes-file-preview/<UUID>/<fileName>`
      with `.progress` events (≥64 KB granularity, nil fraction without `Content-Length`) and
      `.finished(url)`; cancellation / failure removes the partial directory; `removeTemp` deletes
      the file's parent `<UUID>` directory
- [x] (manual, no checkbox needed in code) sanity-check the real routes once against a running
      agent: `curl -H "X-Hermes-Session-Token: …" "$URL/api/fs/read-text?path=~/x.txt"` — and
      confirm whether `session_id` wants the stored id (`sessionKey`); note the answer in
      `docs/features/file-preview.md` in Task 10 — **skipped (not automatable: no running
      agent in the unattended run)**; the `session_id` = stored-id question stays OPEN for the
      docs task (Task 11) and the Post-Completion manual verification
- [x] write `MockURLProtocol` tests: request path + query items + auth header for token and
      bearer modes; `readText` decode; `readData` decode of a tiny PNG data URL; 404 →
      `RESTError.notFound`; 403 / 413 → `.server(status:detail:)`; malformed data URL → `.decoding`
- [x] write download tests: bytes land in a file named `fileName`, progress reaches 1.0 with
      `Content-Length`, nil fractions without it, `removeTemp` deletes the directory, a thrown
      transport error cleans up the partial directory
- [x] write `DataURL` tests (valid, missing `;base64`, bad base64, empty payload)
- [x] run `swift test` — must pass before task 3
- ➕ `live` also takes `temporaryDirectory:` (default `FileManager.default.temporaryDirectory`)
  so the download tests own a scratch root and can assert "no folder left behind" exactly;
  `MockURLProtocol.Stub` gained `failAfterBody` (body first, then the transport error) for
  the mid-transfer cleanup test. An empty base64 payload parses to empty `Data` (a 0-byte
  file is a real file; the view's image-decode fallback shows the generic card). A cancelled
  consumer removes the partial directory synchronously from the stream's `onTermination`; a
  download that already finished before the effect was cancelled keeps its file until the
  sheet's `removeTemp` / the OS clears `tmp` (accepted residual).

### Task 3: `FilePreviewFeature` reducer

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/FilePreviewFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/FilePreviewFeatureTests.swift`

- [x] add `State` (public init), `Content`, `Reason`, `GenericInfo`, `ShareState`, `Action` per
      Technical Details; `CancelID.load / .download / .copyFeedback`;
      `copiedFeedbackDuration = .seconds(1.5)` (duplicated per feature, per the toast idiom)
- [x] implement `.task` / `.retry` → load effect by kind (`readData` for image/pdf, `readText`
      otherwise), `.loaded` fold (`binary` → generic, error → reason mapping or `.failed`)
- [x] implement share lifecycle: `.shareTapped` → `.downloading(nil)` + `download` effect;
      `.downloadEvent`; `.downloadFailed` → `.idle` + `shareError`; `.cancelDownload`;
      `.shareDismissed`
- [x] implement `.copyPath` (pasteboard + token bump + dwell) and `.copiedFeedbackElapsed`
- [x] write `TestStore` tests: image success, pdf success, text success (truncated flag
      preserved), binary → `.generic(.unsupported)` with byteSize, 404 → `.notFound` with
      server detail, 403 → `.protected`, 413 → `.tooLarge`, transport error → `.failed` then
      `.retry` succeeds
- [x] write share tests: progress sequence → `.ready(url)`; cancel mid-download → `.idle` and the
      effect is cancelled; failure → `.idle` + `shareError`; `.shareDismissed` → `.idle` keeps no
      URL but a second `.shareTapped` restarts cleanly
- [x] write copy-toast tests with `TestClock`: token bumps on each copy, clears after 1.5 s, a
      second copy inside the dwell restarts it
- [x] run `swift test` — must pass before task 4
- ➕ `State` gained `downloadedURL: URL?` alongside `share`: `.shareDismissed` drops `share` to
  `.idle` (no URL in the share state) while the finished temp file's URL is kept here, so a
  second Share re-presents instantly with no round-trip and **Task 4's dismiss cleanup reads
  `downloadedURL`** (not `share`) for `removeTemp`. `.task` loads only while `content ==
  .loading` (a re-appearance never discards a loaded preview; `.retry` is the explicit reload).
  The client types a 404 as `RESTError.notFound` (no detail); the reducer ALSO maps
  `.server(404, detail)` → `.generic(.notFound, serverDetail:)` so the sandbox hint is kept
  if the transport ever surfaces it — the "404 with server detail" test covers that shape.

### Task 4: Wire the child into `ChatFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ChatFilePreviewTests.swift`

- [x] add `@Presents public var filePreview: FilePreviewFeature.State?` and the two actions
      (`fileReferenceTapped(path:)`, `filePreview(PresentationAction<…>)`)
- [x] implement `.fileReferenceTapped`: ignored while presented; otherwise seeds the child with
      `path`, `sessionID: state.sessionKey`, `state.connection`
- [x] implement `.filePreview(.dismiss)` cleanup: `removeTemp` for a `.ready(url)` share before
      `.ifLet` nils the state; compose `.ifLet(\.$filePreview, action: \.filePreview)`
- [x] confirm `teardown` / slot nil-out needs no extra cancel (child effects die with `.ifLet`) —
      add a comment next to the existing `CancelID` teardown list saying why `filePreview` is
      not listed
- [x] write tests: tap seeds the child with the session key and connection; a second tap while
      presented is a no-op; dismiss with a ready share calls `removeTemp` with that URL; dismiss
      during `.downloading` cancels the download effect (no trailing `downloadEvent` lands);
      `Equatable` state round-trips through the existing snapshot persist path unaffected (the
      child is not persisted)
- [x] run `swift test` — must pass before task 5
- ➕ the dismiss cleanup reads the child's `downloadedURL` (Task 3's addition), not `share`:
  after `.shareDismissed` the share state is already `.idle` while the temp file is still on
  disk, and that file must go when the preview does. A dismiss with no finished download calls
  nothing (a cancelled in-flight download cleans its own partial folder via the stream's
  `onTermination`). The dependency is held as `filePreviewClient` in the reducer so it can't be
  confused with `state.filePreview`. `ChatSnapshot` was already a fixed projection (model /
  reasoning / usage / rows), so no persistence exclusion was needed — the persist test proves it.

### Task 5: Attach `hermes-file:` links in both prose renderers

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/SelectableText.swift`
- Modify: `HermesMobile/Sources/Features/Chat/MarkdownText.swift`
- Modify: `HermesMobileTests/ChatSnapshotTests.swift` (or create `FileReferenceLinkSnapshotTests.swift`)

- [x] `ProseAttributedBuilder.inlineRuns`: for a run with `run.link`, swap to
      `FileReference.url(for:)` when `path(fromLinkTarget:)` returns a path; for a run without a
      link, map `FileReferenceScanner.segments(text)` to sub-runs, attaching `.link` and the tint
      color to `.file` segments (code-span font preserved on the path)
- [x] `MarkdownText.inline`: same segment mapping on the `AttributedString` runs so blockquotes,
      list items and table cells carry the link too
- [x] `SelectableText`: add the `Coordinator` `UITextViewDelegate` with
      `primaryAction(for:defaultAction:)` (our scheme → `UIAction` calling
      `context.environment.openURL`; else `defaultAction`) and `menuConfiguration(for:defaultMenu:)`
      (nil for our scheme); set `view.delegate = context.coordinator`
- [x] verify `ChatRow.copyText` and the code-block copy path still copy the raw source (the
      `MEDIA:` display swap is render-only) — assert in an existing `ChatRowCopyTests` case
- [x] write a snapshot: assistant bubble with `Saved to /home/e/out/report.pdf and MEDIA:/a/b.png`
      (link tint on the path, filename shown for the tag), light + dark; and one blockquote line
      with a path through the `Text` path
- [x] run `make snapshot` twice (record, then assert) — must pass before task 6
- ➕ the segment mapping lives ONCE, in `MarkdownText.inline`; `ProseAttributedBuilder.inlineRuns`
  now consumes that `AttributedString` (it used to run the same markdown parse itself) and only
  resolves fonts/colours, so the two renderers cannot disagree on which ranges are links. The
  coordinator recognises our scheme via `FileReference.path(from:)` (scheme AND host), not a bare
  scheme compare, and re-captures `openURL` on every `updateUIView` (the cell-builder handler is
  environment state). New suite `FileReferenceLinkSnapshotTests` (3 snapshots + 3 attribute
  tests over `ProseAttributedBuilder.make` / `MarkdownText.inline`); `make snapshot` is now
  248/248 — the CLAUDE.md / `docs/development.md` "242 of 242" figures are updated in Task 11 with
  the final count. The bubble fixture adds a second paragraph (backticked `~/` path, `file://`
  markdown link, an `https` markdown link that must stay system-routed) on top of the plan's line.

### Task 6: `ChatView` tap hook and sheet presentation (skeleton sheet)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Create: `HermesMobile/Sources/Features/Chat/FilePreview/FilePreviewSheet.swift`
- Create: `HermesMobile/Sources/Features/Chat/FilePreview/GenericFileCardView.swift`
- Create: `HermesMobileTests/FilePreviewSnapshotTests.swift`

- [x] add one `OpenURLAction` in `ChatView` (`hermes-file:` → `store.send(.fileReferenceTapped
      (path:))`, `.handled`; otherwise `.systemAction`) and apply it to the `transcriptCell`
      content and to the chat body
- [x] add `.sheet(item: $store.scope(state: \.filePreview, action: \.filePreview))` presenting
      `FilePreviewSheet` with `.presentationDetents([.large])`
- [x] implement `FilePreviewSheet`: `NavigationStack`, filename title, `Done`, bottom toolbar
      with `Copy path` and `Share` (Share disabled while `.downloading`), content switch with
      `ProgressView` for `.loading`, `GenericFileCardView` for `.generic`, an error view with
      `Retry` for `.failed`; text/image/pdf branches render placeholder views until Task 7/8
- [x] implement `GenericFileCardView` (symbol, filename, centered selectable path, byte size,
      reason copy, optional server detail)
- [x] write snapshots: generic card (unsupported with size; not found with server detail;
      protected; too large), error state with Retry, loading — pinned width/height, light + dark
- [x] run `tuist generate`, `make snapshot` twice — must pass before task 7
- ➕ the sheet's content region is an internal `FilePreviewSheet.content` so the snapshot suite
  renders it at a pinned 390×600 via `componentImage()` (8 captures: four generic reasons,
  failed, loading; light variants for unsupported + failed); two `deviceImage()` captures of the
  whole sheet pin the chrome (inline file-name title, `Done`, Copy path / Share bottom bar — iOS 26
  renders bottom-bar labels icon-only, the text stays the accessibility label). `.failed` uses
  `ContentUnavailableView` with a prominent Retry. `Done` is the environment `dismiss` (nils the
  scoped `.sheet(item:)` binding → `.filePreview(.dismiss)`), matching `ToolDetailSheet`. Every
  snapshot store swallows `.task` (`Reducer.ignoring`) so the unimplemented test client is never
  hit. `make snapshot` is now 258/258.

### Task 7: Text preview and copy toast

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/FilePreview/MonospacedFileTextView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/FilePreview/FilePreviewSheet.swift`
- Create: `HermesMobileTests/FilePreviewTextLayoutTests.swift`
- Modify: `HermesMobileTests/FilePreviewSnapshotTests.swift`

- [x] implement `MonospacedFileTextView` (`UITextView` representable: scrollable, selectable,
      monospaced body with Dynamic Type, no data detectors) with a caption row (`language`) and
      the "Showing first 512 KB" banner when `truncated`
- [x] wire `.text` in `FilePreviewSheet`; add the copy toast overlay off `copiedToken` using the
      existing overlay idiom (placed before the bottom toolbar inset so nothing swallows it) with
      the VoiceOver announcement
- [x] write the measured `UIWindow` test: a 400-line fixture hosted at 390×600,
      `.dynamicTypeSize(.large)` → `contentSize.height > bounds.height`; and a short fixture →
      no scroll
- [x] write snapshots: text preview (short, with language caption), truncated banner variant,
      copied-toast visible — pinned width **and** height
- [x] run `make snapshot` twice — must pass before task 8
- ➕ the toast IS the shared `CopiedToastView`, which gained a `message` parameter (default
  unchanged: "Session ID copied"; the sheet passes "Path copied") so the VoiceOver announcement
  stays keyed on the token in one place. It is overlaid on the sheet's `content` region (inside
  the `NavigationStack`, whose safe area already ends at the bottom bar), so the snapshot of
  `content` carries it — but the copied-toast baseline is a whole-sheet `deviceImage()`
  capture like every other toast baseline: the glass capsule and the label it composites do
  not draw in a `componentImage()` layer render (measured — only the SF Symbol survived). The
  text view's font is the UNSCALED body size (17pt) in `monospacedSystemFont` run through
  `UIFontMetrics(forTextStyle: .body)`, not `preferredFont(forTextStyle:)` re-scaled — the
  latter compounds the Dynamic Type scale; `adjustsFontForContentSizeCategory` rescales it
  live. The layout suite (4 tests) also pins that the text view FILLS the region for a short
  file and that the caption + banner only take a strip off the top. `make snapshot` is now
  267/267 (5 new baselines; the Task 11 count update stands).

### Task 8: Image and PDF previews

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/FilePreview/ZoomableImageView.swift`
- Create: `HermesMobile/Sources/Features/Chat/FilePreview/PDFKitView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/FilePreview/FilePreviewSheet.swift`
- Modify: `HermesMobileTests/FilePreviewSnapshotTests.swift`

- [x] implement `ZoomableImageView` (`UIScrollView` + `UIImageView`, min 1× / max 4×, double-tap
      toggle, image centered on layout) and the view-side fallback: `UIImage(data:) == nil` →
      `GenericFileCardView(reason: .unsupported)`
- [x] implement `PDFKitView` (`PDFView`, `autoScales`, `displayMode = .singlePageContinuous`,
      document from `Data`)
- [x] wire `.image` / `.pdf` in `FilePreviewSheet`
- [x] write snapshots: image preview from an in-test generated 64×64 PNG; PDF preview from an
      in-test `UIGraphicsPDFRenderer` one-pager; undecodable image bytes → generic card
- [x] run `make snapshot` twice — must pass before task 9
- ➕ the decode helpers are static on the renderers (`ZoomableImageView.image(from:)`,
  `PDFKitView.document(from:)` — the latter also rejects a zero-page document), so the sheet
  never imports PDFKit; the two branches are private `Equatable` sub-views (`ImagePreviewBody`
  / `PDFPreviewBody`, `.equatable()`) keyed on the bytes, so a toast or share-bar re-render
  neither re-decodes a multi-megabyte image nor resets its zoom. The fallback card carries the
  byte count (known from the data), mirroring the reducer's `.other` data-route fallback. An
  image smaller than the region scales UP to fit at 1× (system-viewer behaviour; the fitted
  size is the 1× content size, re-fitted only when the bounds change so a zoom-driven layout
  pass never resets it). `PDFView` renders fully in a `componentImage()` layer render — no
  `deviceImage()` route needed — and was stable across three consecutive `make snapshot` runs.
  `make snapshot` is now 270/270 (3 new baselines; the Task 11 count update stands).

### Task 9: Share download UI

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/FilePreview/ActivityShareSheet.swift`
- Modify: `HermesMobile/Sources/Features/Chat/FilePreview/FilePreviewSheet.swift`
- Modify: `HermesMobileTests/FilePreviewSnapshotTests.swift`

- [x] implement `ActivityShareSheet` (`UIActivityViewController` representable, iPad popover
      anchored to the toolbar, completion → `.shareDismissed`)
- [x] add the download progress overlay (determinate `ProgressView` when the fraction is known,
      indeterminate otherwise, Cancel → `.cancelDownload`) and the `shareError` banner
- [x] present `ActivityShareSheet` via `.sheet(item:)` bound to `share == .ready(url)`
- [x] write snapshots: downloading at 45 %, downloading indeterminate, share error banner
- [x] run `make snapshot` twice — must pass before task 10
- ➕ the share sheet is a SwiftUI `.sheet(item:)` (detents `.medium` / `.large`) over a private
  `ShareItem` (`Identifiable` by the URL string) derived from `share == .ready(url)` — NOT a
  popover, so no iPad source-view anchor is needed on any device. The activity controller is a
  child of the sheet's hosting controller, so its completion handler and the binding's nil-set
  can both fire for one dismissal; the sheet sends `.shareDismissed` through one guarded helper
  (`share` must still be `.ready`), so the reducer sees it once. The reducer already cleared
  `shareError` on `.shareTapped` (Task 3) — no HermesKit change. The status strip is a bottom
  `safeAreaInset` on the `content` region, attached AFTER the toast overlay (the toast's
  `.safeAreaPadding(.bottom)` then lifts it above the strip): determinate = label with the
  percentage + Cancel over a linear bar; indeterminate = a small spinner leading the label, no
  bar (an empty track would read as stuck at 0); the error strip reuses the chat banner idiom
  (red caption over `red.opacity(0.12)`). Appearance / swap animates with `.snappy`, keyed on a
  three-state kind (never on a progress tick), nil under reduce-motion. The strip draws in a
  `componentImage()` layer render (solid backgrounds, no glass), so 4 captures are `content`
  renders at 390×600 (45 % dark + light, indeterminate, error) plus one whole-sheet
  `deviceImage()` of the determinate case pinning the strip above the bottom bar with Share
  disabled. `make snapshot` is now 275/275 (5 new baselines; the Task 11 count update stands).

### Task 10: Verify acceptance criteria
- [x] verify every detection shape from the Overview is tappable in a real chat (link, `MEDIA:`,
      bare path, backticked path, path followed by punctuation) and `https` links still open Safari
      — **(static + unit check; live-agent tap run skipped — not automatable, no running agent.)**
      New `FileReferenceScannerTests.realisticAssistantMessageLinksEveryShapeAndLeavesHTTPSAlone`
      runs one three-line assistant message through the scanner per line and the two link targets
      through `path(fromLinkTarget:)`: bare path + `,`, backticked `~/` path + `.`, `MEDIA:` tag
      (filename display), `file:///` link → path, `https://` link → nil on both routes. Grep of
      `ChatView.swift` confirms the ONE `OpenURLAction` (`openFileReference`) returns
      `.systemAction` for every URL `FileReference.path(from:)` rejects and is installed on both
      the chat body and `transcriptCell`; `SelectableText.Coordinator` hands non-`hermes-file:`
      links back to `defaultAction` (Safari) and keeps their default menu.
- [x] verify edge cases: image over 16 MB → too-large card with working Share; binary file →
      generic card; missing file → not-found card; `.env` → protected card; dismiss mid-download
      leaves no temp directory behind; a second Share after dismissing the share sheet is instant
      — **(reducer/client tests only; live-agent run skipped — not automatable.)** Covered by
      `FilePreviewFeatureTests` (`payloadTooLargeShowsTheTooLargeCard`,
      `binaryVerdictShowsTheGenericCardWithByteSize`, `notFoundShowsTheNotFoundCard` +
      `…WithServerDetail`, `forbiddenShowsTheProtectedCard`,
      `shareDismissedReturnsToIdleAndASecondShareIsInstant` — one download for two Shares),
      `ChatFilePreviewTests.dismissDuringADownloadCancelsTheChildEffect` (`.ifLet` cancels the
      stream) + `FilePreviewClientTests.downloadCancelledByTheConsumerRemovesThePartialDirectory`
      (the partial `<UUID>` folder is gone). "Working Share on the too-large card" was the one
      gap: new `FilePreviewFeatureTests.shareOnTheTooLargeCardStillDownloads` asserts `.shareTapped`
      on `.generic(.tooLarge)` starts the download and reaches `.ready`; the view disables Share
      only while `share == .downloading`, never on `content` (`FilePreviewSheet.isDownloading`).
- [x] run full test suite: `make test` and `make snapshot` (clean, no re-records outside this PR)
      — `make test`: `Test run with 1862 tests in 79 suites passed after 6.784 seconds with 2 known
      issues` (the 2 known issues are the pre-existing `withKnownIssue` wraps; 1860 + the 2 tests
      added here). `make snapshot`: `Executed 275 tests, with 0 failures (0 unexpected)` /
      `** TEST SUCCEEDED **`; `git status --porcelain -- HermesMobileTests/__Snapshots__/` is empty,
      so nothing was re-recorded. `HermesKit/Package.resolved` restored before the commit.
- [x] verify iPad regular width: sheet presents over the split detail; Share popover anchors
      — **(static review only; interactive iPad check skipped — no device/simulator run.)**
      `ChatView.swift` attaches `.sheet(item: $store.scope(state: \.filePreview, …))` to the chat
      body itself (next to the tool-detail and model-picker sheets), so in regular width it presents
      over the `NavigationSplitView` detail the slot occupies. `FilePreviewSheet` presents the
      activity controller through a SwiftUI `.sheet(item: shareItem)` (detents `.medium`/`.large`),
      not a popover, so no iPad `sourceView`/anchor is needed and the "popover anchors" wording is
      moot (Task 9 decision).
- [x] verify VoiceOver reads the path link as a link and announces "Copied"
      — **(static review only; VoiceOver run skipped — not automatable.)** `MarkdownText.inline`
      sets `piece.link = FileReference.url(for:)` on every file segment; `ProseAttributedBuilder`
      copies `run.link` into `NSAttributedString.Key.link`, which `UITextView` exposes to VoiceOver
      as a link (`FileReferenceLinkSnapshotTests` attribute tests assert the `.link` attribute on
      both renderers' output). `ZoomableImageView` is one accessibility element (`isAccessibilityElement`,
      `.image` trait) labelled with the file name. `CopiedToastView` posts
      `AccessibilityNotification.Announcement(message)` on every `copiedToken` change; the sheet's
      actual announcement string is **"Path copied"** (`FilePreviewSheet.copiedMessage`), not "Copied".

### Task 11: [Final] Update documentation
- [x] create `docs/features/file-preview.md`: detection grammar (with the false-positive corpus),
      the `hermes-file:` URL convention, the one-`openURL`-hook rule, server-decides-binary,
      the no-capability-flip rationale, the share temp-file lifecycle, the `session_id` answer
      from Task 2, and known limitations (no relative paths, no inline images, markdown shown as
      plain text, no bare paths with spaces) — the `session_id` item is recorded as OPEN (what the
      client sends, to be confirmed against a live agent in Post-Completion), not answered
- [x] add a 5–8 line CLAUDE.md bullet under **Transcript & chat UI** (rule + pointer only) — plus
      the `make snapshot` figure 242 → 275 there and in `docs/development.md`
- [x] add a line to the README feature overview
- [x] move this plan to `docs/plans/completed/` (deferred to the exec orchestrator's move-plan step)

## Post-Completion

**Manual verification:**
- Against a live self-hosted agent in token, password and OAuth modes: open a session where the
  agent produced a PDF, a PNG and a log file; tap each; share the PDF to Files.
- Against a Hermes Cloud agent: confirm `/workspace/...` sandbox paths resolve via `session_id`,
  and confirm the 404 detail copy when a path lives only inside the sandbox.
- TestFlight build after merge (internal by default).

**Possible follow-ups (not in this plan):**
- Inline image rendering in the transcript (desktop parity).
- Render `.md` previews through `MarkdownText`.
- File references inside tool detail sheets and `preview.open` events.
