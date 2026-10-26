import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
@Generable
struct GeneratedBreakIdea {
    @Guide(description: "One short sentence telling the person what to do, starting with a verb, under 20 words")
    var idea: String
}
#endif

/// Ideas from Apple Intelligence's on-device model. Every failure, an unavailable model or a slow answer is nil:
/// the overlay then hides the line.
enum BreakIdeas {
    @MainActor private static var lastFocus: String?

    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    /// `recent`: the ideas shown lately, oldest first; an answer too close to one of them is asked again.
    @MainActor
    static func generate(length: TimeInterval, level: Int, interests: [String], surprise: Bool,
                         recent: [String] = [], timeout: TimeInterval = 10) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), available else { return nil }
        var rng = SystemRandomNumberGenerator()
        let focus = surprise ? nil : BreakIdeaPrompt.focus(from: interests, after: lastFocus, using: &rng)
        lastFocus = focus ?? lastFocus
        let angles = BreakIdeaPrompt.angles(level: surprise ? 2 : level).shuffled(using: &rng)   // a new one each try
        return await BreakIdeaPrompt.fresh(recent: recent, timeout: timeout) { avoid, attempt in
            let prompt = BreakIdeaPrompt.prompt(length: length, level: level, focus: focus,
                                                angle: angles[attempt % angles.count], avoid: avoid)
            let session = LanguageModelSession(instructions: BreakIdeaPrompt.instructions)
            // Apple documents temperature as 0 to 1
            let options = GenerationOptions(temperature: surprise ? 1 : 0.9, maximumResponseTokens: 120)
            guard let reply = try? await session.respond(to: prompt, generating: GeneratedBreakIdea.self, options: options)
            else { return nil }
            // plain text only: the model sometimes adds Markdown emphasis or quotes
            let text = reply.content.idea.replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
            return text.isEmpty ? nil : text
        }
        #else
        return nil
        #endif
    }
}
