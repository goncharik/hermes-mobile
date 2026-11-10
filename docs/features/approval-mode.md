# Approval mode (#118)

The composer lightning button selects **Manual**, **Smart**, or **Off**. Off uses a filled,
accent-colored bolt; the other modes use the outline. This is a **profile-wide** server
setting, not a per-session or device preference: it applies to every chat in the profile,
including CLI, Telegram and cron. The picker says so explicitly; it does not add a
confirmation dialog. `/yolo` remains hidden from the slash catalog.

## Capability and discovery

`desktopContract >= 3` gates approval RPCs and the control. Older and unknown contracts
must not probe `config.get` or issue `config.set` for `approvals.mode`. The control is shown
once a recognized mode is confirmed; unsupported/unknown values are never guessed.

After ready or hydrate (including fresh-session ready), issue `config.get` with
`{key: "approvals.mode", profile}`. An explicitly selected default profile is sent as
`"default"`; custom names are preserved. When `profileName` is nil, omit `profile` so the
server uses its launch/unscoped profile, which need not be default. Reads and writes use
this same scope rule. Contract discovery in `session.info` can initiate the
first read even if the agent has not built yet. Lazy create/resume payloads may omit
`approval_mode` and other runtime fields: omission is **not** lack of support and never
clears a known mode or the rollback value of a pending write.

## Reconciliation and writes

The gateway can broadcast the writer's `approval_mode` to sessions in *other* profiles.
Every recognized `session.info` mode is therefore only a refresh hint, even when equal to
the display: cancel/reconfirm an outstanding read so an older completion cannot win. Keep
the current display until a profile-scoped `config.get` confirms the policy. An absent or unknown event value
never clears an established policy. Read responses carry their captured profile and are
ignored outside that profile. New reads cancel older reads.

Selection is optimistic and single-flight. While one write is pending, rows are disabled
and further picks are ignored, not queued or used to cancel/replace the write. Cancel an
older read before starting the write so it cannot repaint the optimistic selection.
Unscoped broadcasts and hydrate refreshes during a write do not mutate its rollback.
`config.set` sends `{key: "approvals.mode", value, profile}` and its recognized normalized
`value` is authoritative on success, even if it differs from the selected value.

On failure, restore the last confirmed mode, show a failure banner, and perform a scoped
refresh to reconcile any changes from other clients. A failed/malformed read preserves the
known display and reports an unavailable banner; it does not invent a mode. Teardown and
socket closure cancel approval work and discard optimistic state. Reconnect re-reads the
profile setting. No approval mode is persisted as a device preference.

## Presentation and regression coverage

The popover scrolls at accessibility sizes and lets the system supply the glass background.
Each row combines title/detail for accessibility, exposes the selected trait, and hides the
decorative checkmark from VoiceOver. The scope notice is part of the scrollable content.

`ApprovalModeTests` covers the contract gate, lazy hydration, explicit profile parameters,
normalized acknowledgments, single-flight selection, rollback, foreign-profile broadcasts,
read cancellation, teardown and disconnect. `ComposerSnapshotTests` includes Manual and Off
at 390-point phone width with speaker and attachments enabled, and popover content at
Large and Accessibility 5. Snapshot baselines must be recorded and replayed on the supported
Mac simulator; do not use the global record wrapper to replace unrelated baselines.
