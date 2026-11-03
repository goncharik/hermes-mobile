# File preview in chat

The short rule lives in `CLAUDE.md` → "Transcript & chat UI"; this doc is the full contract.
Design history: `docs/plans/completed/20261103-file-preview-in-chat.md`.

When the agent names a file that lives on the agent host, the reference is **tappable in place**
in the transcript and opens a modal `FilePreviewSheet`: text, images and PDFs get a real preview;
everything else gets a generic card (name, full path, size, a one-line reason). Every kind offers
**Copy path** and **Share** (the bytes are downloaded to a temp file and handed to the iOS share
sheet). No inline images, no attachment chips, no new row kind, no change to transcript row
identity — row heights stay deterministic and nothing loads until tapped. Desktop reference:
`apps/desktop/src/lib/markdown-preprocess.ts` + `lib/chat-messages/parts.ts`; this feature adds
bare paths on top because the phone's sessions get the TUI prompt, which tells the model to state
plain paths rather than `MEDIA:` tags.

## Detection grammar (`FileReferenceScanner`, HermesKit)

Message events and history rows carry **no structured attachment field**, so detection is text
parsing — exactly as on desktop. The scanner is pure, works on ONE prose line (both renderers
already go line by line; paths never span lines) and returns `[InlineFileSegment]` =
`.text` | `.file(display:path:)`. Three shapes; earlier passes claim their ranges:

1. **Markdown link targets** — not the scanner's job. The inline markdown parse already produced
   them as `.link` runs; `FileReference.path(fromLinkTarget:)` accepts a `file:` URL
   (`file:///a%20b.pdf` and `file://localhost/...` both → `/a b.pdf`, percent-decoded) or a
   scheme-less target starting with `/` or `~/`, and returns nil for anything else (`https:`,
   `mailto:`, anchors, relative paths), which stays untouched. The label is kept as display text.
2. **`MEDIA:` tags** — `MEDIA:` immediately followed by a double-quoted path (may contain spaces)
   or a run of non-whitespace characters that stops at whitespace, `"` or a backtick (so an
   inline-code closer is never swallowed). A bare capture sheds trailing sentence punctuation; the
   quoted form is the escape hatch and keeps it. The capture must be a **plausible path** (contains
   `/`, or a `.` with content after it — desktop's `isPlausibleMediaPath`), so `MEDIA:...` stays
   prose: a dead link is worse than no link. Display text = last path component.
3. **Bare absolute paths** — `NSRegularExpression` (ICU, because the lookbehind must be guaranteed
   on both macOS and iOS and the codebase has no Swift `Regex` precedent):

   ```
   (?<![\w/~.])(?:~(?:/[A-Za-z0-9._\-+@%~]+)*|(?:/[A-Za-z0-9._\-+@%~]+)+)/[A-Za-z0-9._\-+@%~]*\.[A-Za-z0-9]{1,10}(?!\w|\.\w)
   ```

   A `/` or `~/` root at a non-word boundary, filename-safe segments, and a final segment with a
   **1–10 character extension**. A `/` root needs at least one directory segment (`/report.pdf`
   alone is too close to a fraction or a URL path) while `~/x.md` is unambiguous and needs none.
   The trailing lookahead keeps `/x/y.toolongextension` from matching its first ten letters and
   `/x/y.z.longext` from matching `/x/y.z`, while a sentence period after the extension
   (`/a/b.pdf.`) still ends the match cleanly. Display text = the matched path.

**Trailing-punctuation trim**: `splitTrailingPunctuation` strips `.,;:)]}'"` and backticks off a
match. For bare paths it is a documented no-op safety net (the regex already ends every match on
an extension character); it IS load-bearing for the unquoted `MEDIA:` branch.

**False-positive corpus** (all must stay plain text; `FileReferenceScannerTests` is the guard):
`https://host/a/b.pdf` (the `//` is preceded by `:`), `1/2/2026`, `3/4`, `./out/x.pdf`,
`src/foo.swift`, `/tmp`, `/usr/bin/python`, `a/b.c`, `/report.pdf`, `/x/y.toolongextension`, an
11-character extension, `/a/b.pdf_old`, mid-word `foo/bar.txt`, `file://` inside prose,
`MEDIA:...`.

**Deliberately not linked**: relative paths, bare paths with spaces (quote them in a `MEDIA:` tag
or a markdown link), extension-less paths (`/usr/bin/python`), dotfiles by bare path (`.env` has
no extension by `fileExtension(of:)`). The extension requirement and the filename-safe character
class keep false positives down; the generic card makes a residual one harmless.

## The `hermes-file:` URL and the ONE `openURL` hook

`FileReference.url(for:)` → `hermes-file://preview?path=<encoded>`; every character outside the
RFC 3986 unreserved set is percent-encoded (incl. `/`, `?`, `#`, `%`, `+`, spaces, non-ASCII) so
arbitrary paths round-trip byte-for-byte through `FileReference.path(from:)`, which returns nil
for any other scheme or host and for an empty path. The scheme is private to the app — nothing
else produces it.

**The segment mapping lives ONCE, in `MarkdownText.inline`**: markdown `file:`/`/abs`/`~/` link
targets are re-targeted via `path(fromLinkTarget:)` keeping their label, link-less runs are split
by `FileReferenceScanner.segments` with run attributes preserved, and `MEDIA:` tags display their
filename. `ProseAttributedBuilder.inlineRuns` (the `UITextView` path) consumes that
`AttributedString` and only resolves fonts and tint, so the two renderers cannot disagree on
which ranges are links. Blockquotes, list items and table cells (the SwiftUI `Text` path) carry
the same link.

Both renderers end in SwiftUI's `openURL`: `SelectableText`'s `Coordinator`
(`UITextViewDelegate`) answers `primaryAction(for:)` with a `UIAction` calling the captured
`context.environment.openURL` for our scheme (recognised via `FileReference.path(from:)` — scheme
AND host, not a bare scheme compare) and `defaultAction` otherwise, and returns a nil
`menuConfiguration` for our scheme (default menu otherwise). `openURL` is re-captured on every
`updateUIView` because the cell-builder handler is environment state.

**`ChatView.openFileReference` is the ONE `OpenURLAction`** that recognises the scheme view-side:
`FileReference.path(from:)` → `store.send(.fileReferenceTapped(path:))` → `.handled`; any other
URL returns `.systemAction` (an `https` link keeps opening Safari). It is installed in TWO places
for one reason: each transcript cell is its own SwiftUI hierarchy inside a
`UIHostingConfiguration`, so nothing set on `ChatView`'s body reaches it — the action goes on the
content `transcriptCell` hands to the collection view AND on the chat body (for links outside the
cells). No closure is threaded through `MessageBubbleView`.

**The `MEDIA:` display swap is render-only.** `ChatRow.copyText` and the code-block copy path
copy the raw source (`ChatRowCopyTests.fileReferencesCopyRawSource`).

## Server routes (`FilePreviewClient`)

The gateway's `hermes_cli/web_routers/files.py`, mounted unconditionally by `web_server.py` —
present on every surface, no capability flag, no JSON-RPC read method:

| Route | Returns | Limit |
|---|---|---|
| `GET /api/fs/read-text?path=&session_id=` | `{binary, byteSize, language, mimeType, text, truncated}` | first 512 KB |
| `GET /api/fs/read-data-url?path=&session_id=` | `{dataUrl: "data:<mime>;base64,…"}` | 16 MB (413 above) |
| `GET /api/fs/download?path=&session_id=` | `FileResponse` attachment, raw bytes | none |

- Same transport rules as every other REST client (`makeURL` / `resolveAuth` / `validate` /
  `serverDetail` from `HermesRESTClient.swift`): the auth header is whatever `RequestAuth` writes
  (`X-Hermes-Session-Token` or `Authorization: Bearer` via `BearerTokenStore.validAccessToken()`;
  cookie mode rides the jar). No query-string token on these routes.
- `path` is sent as it appeared in the transcript (absolute, `~/…`, or decoded from a `file://`
  link). **`session_id` is always passed when the chat has one** — `ChatFeature.sessionKey` =
  `storedSessionID ?? liveSessionID` — so `/workspace/...` sandbox paths map to the host; nil
  omits the parameter (omitted ≠ empty string).
- `FileTextRead` decodes leniently (an absent flag reads as `false`); `readData` decodes the
  `dataUrl` with the pure `DataURL.parse` (base64 only, media-type params dropped; malformed →
  `RESTError.decoding`; an empty payload is empty `Data`, not nil — a 0-byte file is a real file
  and the view's decode fallback shows the generic card).
- 404 → `RESTError.notFound`; every other non-2xx → `.server(status:detail:)` with the server's
  `detail` verbatim; transport failure → `.unreachable`.

**Server decides text vs binary.** Only `.image` (`png jpg jpeg gif webp heic heif bmp tiff tif`)
and `.pdf` are chosen client-side by extension (`FilePreviewKind.infer`) — they need the data-URL
route; **every other extension asks `read-text`** and the server's `binary` flag (null bytes /
control-character ratio) picks the text view or the generic card. There is no client MIME table
beyond those two sets. Whether the image/PDF bytes actually decode is the VIEW's call
(`ZoomableImageView.image(from:)` / `PDFKitView.document(from:)`, which also rejects a zero-page
PDF) — HermesKit stays platform-free; a nil result shows the generic card with the byte count.

**Deliberately NO `*Supported` capability flip** for `/api/fs/*` — the one documented exception to
the gate-by-capability rule. Every other gate exists because the UI it hides would otherwise be a
broken control; here the routes are mounted unconditionally on current agents, and on a very old
agent the link is harmless and the generic "Not found on the agent" card already IS the degraded
state. A flip would only hide a tap that costs nothing.

**`session.create` is unchanged — no `source: "desktop"`.** The desktop sends it to get the
desktop prompt and `MEDIA:` tags; on the phone that would switch the model to a prompt that
assumes desktop-only widgets. Detection covers the TUI prompt's plain paths instead.

## Error → card mapping (`FilePreviewFeature.content(for:)`)

Identical for both routes, nothing swallowed:

| Error | `content` |
|---|---|
| `.notFound` / `.server(404, detail)` | `.generic(.notFound, serverDetail)` — "Not found on the agent" (the detail may say the path lives only inside the sandbox) |
| `.server(403)` | `.generic(.protected)` — "This file is protected" (`.env*`, `auth.json`, `config.yaml`, credential files) |
| `.server(413)` | `.generic(.tooLarge)` — "Too large to preview"; **Share still works** (the download route has no cap) |
| `binary == true` / undecodable bytes | `.generic(.unsupported, byteSize)` — "No preview available" |
| anything else | `.failed(message)` with a prominent Retry (`ContentUnavailableView`) |

The client types a 404 as `.notFound` with no detail; the reducer ALSO maps `.server(404, detail)`
so the sandbox hint is kept if the transport ever surfaces it. `.task` loads only while
`content == .loading` (a re-appearance never discards a loaded preview); `.retry` is the explicit
reload. Share is disabled only while `share == .downloading`, never on `content`.

## Lifecycle: `@Presents` child, dismiss cleanup, temp files

`filePreview` is the **first `@Presents` child on `ChatFeature`**, deliberately: dismissing the
sheet must cancel an in-flight read or a multi-megabyte download, and `.ifLet(\.$filePreview,
action: \.filePreview)` auto-cancellation gives that — the same `ifLet` cancellation the live-chat
slot's "nil-out is mandatory" rule relies on. `filePreview` therefore has NO entry in the
`.teardown` `CancelID` list (comment there): a slot nil-out takes the child and its effects down.

- `.fileReferenceTapped` is a **no-op while a preview is presented** (a double-tap, or a tap
  landing while the sheet animates in, never replaces the preview under the user); otherwise it
  seeds the child with `path`, `sessionKey` and `connection`. `Done` is the environment
  `dismiss` (nils the scoped `.sheet(item:)` binding → `.filePreview(.dismiss)`), like
  `ToolDetailSheet`.
- **Share temp file**: `download` streams `URLSession.bytes(for:)` into
  `temporaryDirectory/hermes-file-preview/<UUID>/<fileName>` — the per-download directory is what
  lets the file keep its REAL name for the share sheet. The status is validated BEFORE the
  directory is created (a 404/403 never leaves a folder); progress is yielded every ≥64 KB
  (`nil` fraction without `Content-Length` → indeterminate strip; a final `1.0` with it); any
  producer failure removes the directory; a consumer that stops iterating (`.cancelDownload`, or
  `.ifLet` tearing the sheet down) removes it synchronously from the stream's `onTermination`.
- **The file outlives the share sheet but not the preview**: `.shareDismissed` drops `share` to
  `.idle` while the URL stays in `State.downloadedURL`, so a second Share re-presents instantly
  with no round-trip. **`.filePreview(.dismiss)` reads `downloadedURL` (not `share`)** and calls
  `removeTemp` fire-and-forget before `.ifLet` nils the state; a dismiss with no finished download
  calls nothing. `removeTemp` deletes the parent `<UUID>` folder only when ITS parent is the
  `hermes-file-preview` root; any other URL loses just the file. Accepted residual: a download
  that finished before the effect was cancelled keeps its file until `removeTemp` or the OS
  sweeps `tmp`.
- **Single-dismissal guard in the sheet**: the activity controller is presented through a SwiftUI
  `.sheet(item:)` over a `ShareItem` (identified by the URL string; detents `.medium`/`.large`;
  NOT a popover, so no iPad source-view anchor). The controller's completion handler and the
  binding's nil-set can both fire for one dismissal, so both go through one guarded
  `sendShareDismissed` (`share` must still be `.ready`) and the reducer sees it once. A late
  `.progress` after Cancel is ignored (`share` must be `.downloading`), so it cannot resurrect
  the bar.
- The child is never persisted: `ChatSnapshot` is a fixed projection (model / reasoning / usage /
  rows), proven by `ChatFilePreviewTests` rather than by an exclusion.
- Copy path: `PasteboardClient` + `copiedToken` bump + 1.5 s `cancelInFlight` dwell (the toast
  idiom, duplicated per feature). The toast is the shared `CopiedToastView` with
  `message: "Path copied"` — the VoiceOver announcement string is "Path copied", not "Copied" —
  overlaid on the sheet's content region inside the `NavigationStack` BEFORE the bottom
  `safeAreaInset` that carries the share status strip, so the strip can't swallow it.

## OPEN: which `session_id`

The client sends `ChatFeature.sessionKey` (`storedSessionID ?? liveSessionID`) — i.e. the STORED
id when the chat has one, the live id before the first persist. Whether the fs routes want the
stored or the live id was **not confirmed against a running agent** (the unattended run had none;
the Task 2 curl check was skipped). It is a Post-Completion manual-verification item: open a
Hermes Cloud session, tap a `/workspace/...` path, and confirm it resolves; also record the exact
404 `detail` copy for a sandbox-only path.

## Known limitations

- No relative paths, no bare paths with spaces, no extension-less paths (quote them in a `MEDIA:`
  tag or a markdown link to get a link).
- No inline images in the transcript (possible later feature; desktop parity).
- Markdown files preview as plain monospaced text, not through `MarkdownText`.
- Tool detail sheets and `preview.open` events are not scanned.
- The text preview is the server's first 512 KB ("Showing first 512 KB" banner when `truncated`);
  Share downloads the whole file.
- An image over 16 MB gets the too-large card, not a preview (Share still works).

## Testing

- `FileReferenceScannerTests` (HermesKit): bare-path positives, the false-positive corpus,
  `MEDIA:` shapes, link targets, URL round-trip (spaces, `~`, unicode, `%`, `?`, `#`),
  `FilePreviewKind`, and one realistic three-line assistant message end to end.
- `FilePreviewClientTests` + `DataURLTests` (HermesKit, `MockURLProtocol`): path/query/auth header
  per auth mode, `session_id` omitted when nil, status mapping, data-URL decode, download
  progress + folder layout + cleanup on failure/cancel, `removeTemp` scope.
- `FilePreviewFeatureTests` (HermesKit, `TestStore`): every content outcome, the share lifecycle
  (progress, cancel, failure, dismiss-then-instant-second-share, share on the too-large card),
  the copy toast under `TestClock`.
- `ChatFilePreviewTests` (HermesKit): tap seeds the child with `sessionKey` + connection;
  second tap is a no-op; dismiss cleanup reads `downloadedURL`; dismiss mid-download cancels the
  child effect; the persisted snapshot excludes the child.
- `ChatRowCopyTests.fileReferencesCopyRawSource`: the display swap is render-only.
- `FileReferenceLinkSnapshotTests` (HermesMobileTests): bubble + blockquote snapshots and
  attribute tests on both renderers' output (`.link`, display text, mono font, tint; `https`
  untouched).
- `FilePreviewSnapshotTests`: the content region at a pinned 390×600 per state (generic reasons,
  failed, loading, text/truncated/plain, image, PDF, undecodable, downloading determinate /
  indeterminate, share error) plus whole-sheet `deviceImage()` captures for the chrome, the
  copied toast (Liquid Glass does not draw in a layer render) and the downloading strip.
- `FilePreviewTextLayoutTests`: measured `UIWindow` tests at 390×600, `.dynamicTypeSize(.large)`
  — a long fixture scrolls (`contentSize.height > bounds.height`), a short one doesn't, the text
  view fills the region, caption + banner only take a strip.
- `make snapshot` is **275/275** after this feature (33 new tests, 26 of them snapshot baselines).
