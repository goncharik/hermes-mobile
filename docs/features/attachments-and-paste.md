# Attachments & image paste (#54, #70)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Composer & input"; this doc is the full contract. Design history:
`docs/plans/completed/`.

## Attachments upload BYTES, never device paths

iOS shares no filesystem with the agent, so `image.attach_bytes` (`content_base64`) /
`pdf.attach` (`content_base64`) / `file.attach` (`data_url`) run before `prompt.submit`;
`file.attach`'s `@file:` ref is prepended to the prompt text. (The desktop's path-based
`image.attach` silently fails against a remote agent — don't copy it.) Old agents lacking these
methods return JSON-RPC `-32601`; `InboundFrame` keeps only the message, so gate via
`GatewayError.isUnknownMethod` (matches `"unknown method"`) → hide the attach affordance.

**Every picker returns a `PickedBatch`** (`items` + `droppedCount`), never a bare
`[PickedItem]`: a selection that produced nothing — a provider that failed, an iCloud original
that never downloaded, a camera `jpegData` that came back `nil`, a type that could not be
re-encoded — drives `.attachmentsDropped` and a banner, while a **cancel** is the empty batch
(no items *and* no drops) and stays silent. The sheet must never dismiss onto an unchanged
composer without saying why.

**A picker owns its presenter (#170).** UIKit presents the photos and Files pickers (remote view
controllers) late: `presentingViewController` is still `nil` when `present` returns, so no check
right after `present` can tell a delayed presentation from a refused one. Releasing the
presenter on that guess left a picker on screen with a `nil` weak delegate, so Done and Cancel
did nothing. `PickerPresenter` instead hangs off its picker as an associated object and
nothing else retains it. UIKit keeps a picker it will show until it is dismissed and drops a
refused one at once. The presenter reports exactly once: from the delegate callback, or from
`deinit` as the silent empty batch, which is how a refused presentation (the widget launch
action raised mid-transition) still finishes. Never add a post-`present` check or a second
owner. The one deliberate exception: a delegate callback's loading `Task` captures the presenter
strongly until it calls `finish`, because the picker is already dismissed by then (a
`[weak self]` there would silently drop the selection).

**Every image source — photos, camera, Files, paste — goes through `PickedImageLoader`**
(`pickedItems` for the provider-backed ones, `rescuedImageItem` for the two that hand over raw
bytes), so a HEIC/AVIF/RAW original or an oversize TIFF is re-encoded or dropped rather than
staged into a chip that can never upload. The binding size limit is the **transport**, not the
handler: the payload rides base64'd in one WebSocket frame and the agent leaves uvicorn's 16 MiB
`ws_max_size` default in place, so a too-big upload kills the socket long before
`_ATTACH_BYTES_MAX_BYTES` (25 MiB decoded) is consulted — see
`PickedImageLoader.maxAttachmentBytes`. (PDFs/files still have no client-side cap; same frame
limit applies to them.)

**A stale session heals the WHOLE upload→submit sequence (#17, #132).** `submitDraft`'s
attachment branch wraps the uploads and the `prompt.submit` together in `withSessionHeal`. On
"session not found" the heal gets a fresh live id, then replays the sequence once (the uploads
are idempotent), falling back to `session.create` for a never-saved session (#132). Full
contract: `docs/architecture.md` → "Session-not-found self-heal".

## The composer is a UIKit text view (#54)

The composer's input is `ComposerTextView`, a `UIViewRepresentable` over
`ComposerInputTextView: UITextView`, **not** a SwiftUI `TextField`: a `TextField` never claims
`paste(_:)` for a non-text clipboard, so for an image-only one iOS does not even *offer* the
**Paste** item (measured in the simulator — see the plan's Task 8 notes). Everything else about
the view is deliberate `TextField(axis: .vertical)` parity — placeholder colour, 1–6 line
growth — and the UIKit traps that parity costs (the `setNeedsLayout` the pinned ceiling needs,
the one-shot `scrollRangeToVisible` on the scroll flip, the caret pin after a programmatic set)
are documented on the type itself.

**The Return key is the one deliberate departure** (#70): it inserts a newline like any other
edit, and the **send button is the only submit path** — the view intercepts nothing (the old
`shouldChangeTextIn` `\n` swallow and its `onSubmit`/Shift+Return key-command workaround are
gone), so `ChatFeature`'s `canSend` guards are now defence-in-depth rather than a live route.

There is deliberately **no focus binding**: a representable gets no `.focused(_:)` — it *is* the
focusable view — so a `@FocusState` here never latches and reading it only ever resigns the
keyboard (it did: the composer lost the keyboard after one keystroke). The transcript dismisses
the keyboard at the UIKit level, via `CollectionTranscriptView`'s
`keyboardDismissMode = .interactive`.

## Offering and handling Paste

**`canPerformAction(_:withSender:)` — NOT `pasteConfiguration`/`canPaste(_:)` — is what makes
UIKit offer the edit menu's Paste item** (a `UITextView` never consults `canPaste(_:)`; that
design tests green and ships broken). The claim probes only `UIPasteboard.hasImages` (metadata;
reading `itemProviders` merely to build a menu would raise the *"Allow Paste"* banner) **and
`acceptsPastedImages`** ← `ComposerView.attachmentsSupported`, the same capability gate that
hides the paperclip — a too-old agent must not be offered a Paste whose only outcome is the
reducer's silent drop (which stays as the backstop for the async window while the providers
load).

`paste(_:)` sends the image providers to `onPasteImages` → `.attachmentsPasted` (staged like any
`PickedItem`, no downstream change) and calls `super` **only when a non-image provider is left
over** — per *provider*, not per pasteboard, so Safari's *Copy Image* (one item carrying the
image **and** the page URL) stages the chip without typing the URL into the message, while a
genuinely multi-item clipboard still pastes its text (known, accepted cost: genuine prose
bundled into the *same item* as an image is dropped — classifying it apart from the URL noise
risks typing a stray URL into the message). Both forwards go through the overridable
`pasteToSuper(_:)` / `superCanPerformAction(_:withSender:)` seams — `super` always reads
`UIPasteboard.general` regardless of the injected `pasteboard`, so tests must assert
**delegation**, never `super`'s verdict.

The provider→`PickedItem` load runs in the view **coordinator**, not a reducer effect — the
implicit pasteboard grant is scoped to the paste command, and `NSItemProvider` is neither
`Sendable` nor `Equatable`, so it cannot ride in a TCA action; an **empty** batch is still
handed over, and the reducer banners it — a paste the menu promised and the user tapped must
never end in silence, and a **partial** loss (`droppedCount > 0`) banners too, after staging the
survivors, so nobody sends two chips believing they pasted three.

**The load is bracketed by `.attachmentsPasting` → `.attachmentsPasted`**, which hold
`pendingPasteCount` and therefore `canSend` down: a paste is the one attachment source with no
modal sheet over it, so Send is reachable while the providers load and a submit that won the
race shipped the message without its image (which then reappeared, orphaned, in the next draft).
It is a counter, not a flag — two fast pastes chain in the coordinator and both are outstanding
at once — and the coordinator delivers unconditionally under a bounded deadline, so the pair can
never leak.

## PickedImageLoader is shared with the picker

**The loader (`PickedImageLoader`) is shared with `PhotoPickerPresenter`**, so every change to
it lands on a shipped path too: one type-selection / naming / byte-loading path, differing only
by `fallbackName` (`"pasted-image"` vs `"photo"`) and by the **per-source load deadline** —
`clipboardLoadTimeout` (a provider that never calls back used to wedge the paste chain for the
lifetime of the process) versus the much longer `pickerLoadTimeout`, because a `PHPickerResult`
performs its iCloud download *inside* `loadDataRepresentation`. It loads the provider's
**original bytes** — no re-encode — choosing the type with a three-pass scan that honours the
provider's own (fidelity-ordered) list within each tier while skipping past extensions the
agent's allowlist rejects; ImageIO re-encodes only the two doomed shapes (nothing acceptable
registered at all, or bytes past `maxAttachmentBytes`) and a provider that cannot even be
decoded is **dropped** rather than staged as a chip whose only outcome is an unretryable 4016 /
a killed socket. Provider-supplied `suggestedName`s are sanitised before travelling to the
agent, and the **decompression-bomb guard runs on every image**, not only the re-encoded ones —
a supported, under-budget PNG declaring 40000×40000 is otherwise handed straight to
`UIImage(data:)` by the attachment chip. The measured specifics — why each tier exists, the HEIC
opacity trap, the two pixel guards, the byte and batch budgets — live in that file's doc
comments; keep them there rather than duplicating them here.
