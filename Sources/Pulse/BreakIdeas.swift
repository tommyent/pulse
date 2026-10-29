import Foundation

/// The ideas that ship with Pulse, read once from Resources/break-ideas.json.
enum BreakIdeas {
    static let all: [BreakIdea] = Bundle.pulseResources.url(forResource: "Resources/break-ideas", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.map(BreakIdeaList.parse) ?? []
}
