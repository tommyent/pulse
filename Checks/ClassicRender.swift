// Built twice by ClassicRenderChecks.sh, against the sources before skins and against today's: the same Classic fixture
// rendered with each, raw RGBA bytes out. Only APIs that both revisions have.
import SwiftUI

extension Bundle { static let pulseResources = Bundle(path: CommandLine.arguments[1])! }
final class OverlayHostingView<Content: View>: NSHostingView<Content> {}

@main enum ClassicRender {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let windows = [UsageWindow(id: "weekly_all", label: "All models", percentUsed: 19, resetsAt: nil),
                       UsageWindow(id: "weekly_model_fable", label: "Fable", percentUsed: 10, resetsAt: nil),
                       UsageWindow(id: "session_5h", label: "Current session", percentUsed: 99, resetsAt: nil)]
        let snap = AccountSnapshot(id: .claude, displayName: "Claude", planLabel: "Ultra", health: .ok,
                                   windows: windows, fetchedAt: .now, source: .mock)
        var finished = BreakAgent(id: "f", app: .codex, blocked: false)
        finished.done = true
        finished.since = .now
        let agents = [BreakAgent(id: "a", app: .claude, blocked: true), BreakAgent(id: "b", app: .codex, blocked: false), finished]
            + (0 ..< 5).map { BreakAgent(id: "i\($0)", app: .grok, blocked: false, idle: true) }
        let fixture = VStack(spacing: 18) {
            HStack(spacing: 22) {
                AgentsRing(board: AgentBoard(agents, now: .now), held: true)
                AgentsRing(board: AgentBoard(), size: 28, showCount: false)
                RingView(account: .claude, percent: 19, secondary: 10)
                RingView(account: .codex, percent: 51, stale: true)
                RingView(account: .grok, percent: 4)
                RingView(account: .antigravity, percent: 12, secondary: 30, hasDisc: true, tertiary: 45)
                RingView(account: .antigravity, pool: 1, percent: 43, nearLimit: true)
                RingView(account: .grok, percent: nil, size: 28, showPercent: false)
                BatteryRing(reading: BatteryReading(percent: 92, onAC: true, minutesLeft: nil), level: .ok)
                BatteryRing(reading: BatteryReading(percent: 8, onAC: false, minutesLeft: nil), level: .critical)
                BreakCup(pausedUntil: nil)
            }
            .padding(20).pulseSurface(in: Capsule())
            UsageCard(snapshot: snap, windows: windows).frame(width: 250)
        }.padding(20).background(Color.white)
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: fixture.environment(\.colorScheme, .dark)
                .environment(\.pulseAppearance, .solid))
            renderer.scale = scale
            let image = renderer.cgImage!
            let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            try Data(bytes: ctx.data!, count: image.width * image.height * 4).write(to: out.appending(path: "classic-\(Int(scale))x.rgba"))
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: out.appending(path: "classic-\(Int(scale))x.png"))
            print("Classic \(Int(scale))x \(image.width)x\(image.height)")
        }
    }
}
