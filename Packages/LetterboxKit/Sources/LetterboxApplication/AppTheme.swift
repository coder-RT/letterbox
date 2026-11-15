import Foundation

/// How the chat looks. A preference only: it changes nothing about how messages travel.
public enum AppTheme: String, CaseIterable, Sendable {
    /// The standard iOS look.
    case classic
    /// An homage to 90s pagers: an LCD-green screen, seven-segment clock and dot-matrix
    /// headings, with messages kept in a clear monospaced font.
    case pager

    public var title: String {
        switch self {
        case .classic: "Classic"
        case .pager: "Pager"
        }
    }
}
