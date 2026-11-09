import Foundation

/// The home screen's bottom-bar tabs: the interactive sessions, the cron jobs with their runs,
/// and Settings. The Cron Jobs tab exists only while there is cron content
/// (`SessionListFeature.State.hasCronContent`); Sessions and Settings always do.
public enum SessionListTab: Equatable, Sendable, CaseIterable {
  case sessions
  case cron
  case settings
}
