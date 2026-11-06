// `HermesWidgetKit` is the Foundation-only slice the widget extension links (no TCA, no GRDB,
// no `UIApplication`). Re-exporting it keeps every `import HermesKit` call site unchanged for
// the types that moved down (`SessionStatus`, `LaunchIntent`, …).
@_exported import HermesWidgetKit
