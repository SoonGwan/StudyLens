import Foundation

/// Error codes reported to the Electron side, which owns all user-facing messages.
public enum SelectedTextError: String, Error, Equatable, Sendable {
    case permissionDenied, noFocusedApplication, noSelection, secureInput, selectionTooLong

    /// Stable wire code used in the helper protocol.
    public var code: String { rawValue }
}

public protocol SelectionAccessibilityClient {
    associatedtype Element: Hashable
    func focusedElement(in application: Element) -> Element?
    func focusedWindow(in application: Element) -> Element?
    func parent(of element: Element) -> Element?
    func children(of element: Element) -> [Element]
    func selectedText(of element: Element) throws -> String?
    func isSecure(_ element: Element) -> Bool
    func isHidden(_ element: Element) -> Bool
}

public struct SelectionResolver<Client: SelectionAccessibilityClient> {
    public let client: Client
    public var maxNodes = 400
    public var timeBudget: TimeInterval = 0.8

    public init(client: Client, maxNodes: Int = 400, timeBudget: TimeInterval = 0.8) {
        self.client = client
        self.maxNodes = maxNodes
        self.timeBudget = timeBudget
    }

    public func resolve(in application: Client.Element) throws -> String {
        let deadline = Date.timeIntervalSinceReferenceDate + timeBudget
        var ancestors: [Client.Element] = []
        var seen = Set<Client.Element>()
        var current = client.focusedElement(in: application)
        for _ in 0..<12 {
            guard let element = current, seen.insert(element).inserted else { break }
            if client.isSecure(element) { throw SelectedTextError.secureInput }
            ancestors.append(element)
            if element == application { break }
            current = client.parent(of: element)
        }
        // Check secure ancestors before reading any child value.
        for element in ancestors where !client.isHidden(element) {
            if let text = try normalized(client.selectedText(of: element)) { return text }
        }
        guard let window = client.focusedWindow(in: application) else { throw SelectedTextError.noSelection }
        var queue = [window]
        var traversed = Set<Client.Element>() // Independent from the ancestor walk.
        var index = 0
        while index < queue.count, index < maxNodes, Date.timeIntervalSinceReferenceDate < deadline {
            let element = queue[index]
            index += 1
            guard traversed.insert(element).inserted,
                  !client.isHidden(element), !client.isSecure(element) else { continue }
            if let text = try normalized(client.selectedText(of: element)) { return text }
            let remaining = max(0, maxNodes - queue.count)
            queue.append(contentsOf: client.children(of: element).prefix(remaining))
        }
        throw SelectedTextError.noSelection
    }

    private func normalized(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard value.utf16.count <= 120_000 else { throw SelectedTextError.selectionTooLong }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= 30_000 else { throw SelectedTextError.selectionTooLong }
        return trimmed
    }
}
