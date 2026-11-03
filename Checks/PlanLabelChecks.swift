@main
enum PlanLabelChecks {
    static func main() {
        // Claude: the profile's own plan name, trimmed; missing or blank shows the company, never a plan built from a tier ID
        let claude: [(String?, String)] = [
            ("Ultra", "Ultra"),
            (" Some New Plan ", "Some New Plan"),
            (" ", "Anthropic"),
            ("", "Anthropic"),
            (nil, "Anthropic"),
        ]
        for (name, want) in claude {
            let got = ClaudeAdapter.planLabel(name)
            assert(got == want, "Claude \(name ?? "nil"): got \(got), want \(want)")
        }

        // Codex: the plan_type IDs in the known map get OpenAI's names; anything else shows the company
        let codex = [("prolite", "ChatGPT Pro Lite"), ("plus", "ChatGPT Plus"), ("pro", "ChatGPT Pro"),
                     ("go", "OpenAI"), ("pro_500", "OpenAI"), ("", "OpenAI")]
        for (plan, want) in codex {
            let got = CodexAdapter.planLabel(plan)
            assert(got == want, "Codex \(plan): got \(got), want \(want)")
        }
        print("Plan label checks passed: the service's own plan name, or the company when it names none")
    }
}
