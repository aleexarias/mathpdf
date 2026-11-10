/// What a text was entered with, and what it expanded to then. It's only
/// expanded again once it changes, so what's drawn keeps the user's commands
/// as they were, whatever has happened to them since.
public struct EnteredExpansion: Sendable {
    private let text: String
    private let expanded: String

    public init(text: String, expanded: String?) {
        self.text = text
        self.expanded = expanded ?? text
    }

    public func expansion(
        of current: String,
        _ expand: (String) throws(LaTeXProblem) -> String
    ) throws(LaTeXProblem) -> String {
        current == text ? expanded : try expand(current)
    }
}
