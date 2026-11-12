import SwiftUI

extension BreakAgent.App {
    var account: AccountID {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .antigravity: .antigravity
        case .grok: .grok
        }
    }
}

extension AgentBoard.Row {
    /// "fix-tests", or the app's name for a pane without a label.
    var pane: String { agent.label.isEmpty ? agent.app.account.displayName : agent.label }
    /// "fix-tests on studio" for a pane on another Mac.
    var place: String { agent.host.isEmpty ? pane : "\(pane) on \(agent.host)" }
}

/// The rail's agents ring: the active agents' icons as overlapping bubbles that fill it, the ring orange while one
/// waits for you and red when one has failed, a tick when one has just finished, and under it (grown) how many need you.
struct AgentsRing: View, Animatable {
    var animatableData: CGFloat { get { size } set { size = newValue } }   // as RingView's
    let board: AgentBoard
    var size: CGFloat = 52
    var showCount = true
    var beside = false   // the number to the ring's right, not under it
    var held = false     // a quiet rule is holding the sound and the alert

    var body: some View {
        let layout = ringItemLayout(beside: beside)
        layout {
            ZStack {
                switch board.tone {
                case .quiet: RingTrack(lineWidth: size * 0.12)
                case .waiting: Circle().stroke(Color.orange, lineWidth: size * 0.12)
                case .failed: Circle().stroke(Color.red, lineWidth: size * 0.12)
                }
                bubbles
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) { if board.justFinished { badge("checkmark") } }
            .overlay(alignment: .bottomTrailing) { if held { badge("bell.slash.fill") } }
            if showCount {
                PercentText(text: "\(board.needsYou)", beside: beside)
                    .foregroundStyle(Color.primary)
                    .transition(.railExtra)
            }
        }
    }

    /// One agent is its plain icon, like any ring's logo. From two, each sits on its own disc; the first, who needs
    /// you most, in front. With no active agent, a dimmed glyph keeps the rail's length.
    @ViewBuilder private var bubbles: some View {
        let shown = board.bubbles, count = shown.apps.count + (shown.more > 0 ? 1 : 0)
        if count == 0 {
            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.3))
                .foregroundStyle(Color.primary.opacity(0.5))
        } else if count == 1 {
            BrandIcon(account: shown.apps[0].account, size: size * 0.4)
        } else {
            let places = AgentBoard.bubblePlaces(count), d = size * places.diameter
            ZStack {
                ForEach(Array(places.centres.enumerated()), id: \.offset) { i, centre in
                    Group {
                        if i < shown.apps.count {
                            BrandIcon(account: shown.apps[i].account, size: d * 0.66)
                        } else {
                            // at the resting size there's room for the sign only
                            Text(size >= 40 ? "+\(shown.more)" : "+")
                                .font(.system(size: max(7, size * 0.15), weight: .bold))
                                .foregroundStyle(Color(white: 0.87))
                                .fixedSize()
                        }
                    }
                    .frame(width: d, height: d)
                    .background(Color(white: 0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.6))
                    .background(Circle().fill(PulsePalette.surface).padding(-1))   // a dark edge, so overlapping discs read apart
                    .offset(x: size * centre.x, y: size * centre.y)
                    .zIndex(Double(count - i))
                }
            }
        }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: max(6, size * 0.15), weight: .bold))
            .foregroundStyle(.white)
            .frame(width: max(11, size * 0.28), height: max(11, size * 0.28))
            .background(Color(white: 0.3), in: Circle())
            .background(Circle().fill(PulsePalette.surface).padding(-1))
            .accessibilityHidden(true).allowsHitTesting(false)
    }
}

/// The agents ring's card: who needs you, who has just finished and who is working, on this Mac and the Macs Rex
/// connects to. A click on a row shows that pane in Rex; nothing is answered from Pulse.
/// Plain values, not the monitor, so it can be rendered on its own.
struct AgentsCard: View {
    private static let most = 10
    let agents: [BreakAgent]
    var dismissed: [String: Date] = [:]
    var hold: AgentHold? = nil   // the quiet rule holding the sound and the alert
    let show: (BreakAgent) -> Void
    let clear: (BreakAgent) -> Void
    var tailEdge: Edge = .trailing
    var tailAt: CGFloat? = nil

    var body: some View {
        // every half minute: waits count up, and a finished agent leaves after its 15 minutes
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let board = AgentBoard(agents, dismissed: dismissed, now: context.date)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill").font(.system(size: 13, weight: .semibold))
                    Text("Agents").font(.headline)
                    Spacer()
                    Text(board.summary).font(.caption).foregroundStyle(PulsePalette.secondary)
                }
                .foregroundStyle(Color.primary)
                if board.rows.isEmpty {
                    Text("No active agents in Rex.").font(.caption).foregroundStyle(PulsePalette.secondary)
                } else {
                    let rows = AgentRows(rows: board.rows, now: context.date, show: show, clear: clear)
                    Group {
                        // more than fit a small screen: they scroll
                        if board.rows.count > Self.most { ScrollView { rows }.frame(height: 400) } else { rows }
                    }
                    .padding(.horizontal, -8)   // a row's highlight reaches past the text's edges
                    let time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
                    if let line = hold?.line(time) {
                        Label(line, systemImage: "bell.slash.fill")
                            .font(.caption).foregroundStyle(PulsePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Idle agents are left out.").font(.caption).foregroundStyle(PulsePalette.secondary)
                    }
                }
            }
        }
        .padding(16)
        .padding(Edge.Set(tailEdge), BubbleShape.tailWidth)
        .frame(width: tailEdge == .trailing || tailEdge == .leading ? 320 + BubbleShape.tailWidth : 320)
        .pulseSurface(in: BubbleShape(edge: tailEdge, at: tailAt))
    }
}

/// The card's and the alert's rows, with a line between those who need you and the rest.
struct AgentRows: View {
    let rows: [AgentBoard.Row]
    let now: Date
    let show: (BreakAgent) -> Void
    var clear: ((BreakAgent) -> Void)? = nil   // the × on a failed row; the alert has none

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if i > 0, rows[i - 1].agent.needsYou, !row.agent.needsYou {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .accessibilityHidden(true)
                }
                AgentRow(row: row, now: now, show: show, clear: clear)
            }
        }
        .padding(.vertical, -5)   // the rows' own padding is their highlight's
    }
}

private struct AgentRow: View {
    let row: AgentBoard.Row
    let now: Date
    let show: (BreakAgent) -> Void
    let clear: ((BreakAgent) -> Void)?
    @State private var hovering = false

    var body: some View {
        let agent = row.agent, state = row.stateText(now), clears = row.state == .failed && clear != nil
        Button { show(agent) } label: {
            HStack(alignment: .top, spacing: 8) {
                BrandIcon(account: agent.app.account, size: 17).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text("\(Text(row.pane).fontWeight(.medium))\(Text(agent.host.isEmpty ? "" : " on \(agent.host)").foregroundStyle(PulsePalette.secondary.opacity(0.8)))")
                            .font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(state).font(.caption).lineLimit(1).fixedSize()
                            .foregroundStyle(row.state == .waiting ? Color.orange : row.state == .failed ? Color.red : PulsePalette.secondary)
                    }
                    // the agent's own line, as plain text; a failed row keeps the line for its ×
                    if !agent.msg.isEmpty || clears {
                        Text(verbatim: agent.msg.isEmpty ? " " : agent.msg)
                            .font(.caption).foregroundStyle(PulsePalette.secondary.opacity(0.82))
                            .lineLimit(1).padding(.trailing, clears ? 21 : 0)
                    }
                }
            }
            .foregroundStyle(Color.primary)
            .opacity(row.state == .working ? 0.78 : 1)
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(Color.white.opacity(hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show in Rex")
        .accessibilityLabel([row.place, state, agent.msg].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint("Shows this pane in Rex")
        // beside the row's button, not inside it: a button in a button never fires
        .overlay(alignment: .bottomTrailing) {
            if clears, let clear {
                Button { clear(agent) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 13, height: 13)
                        .background(Color.white.opacity(0.14), in: Circle())
                        .frame(width: 21, height: 21)   // a target larger than the mark
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4).padding(.bottom, 1)
                .help("Clear this failed mark. Nothing changes in Rex.")
                .accessibilityLabel("Clear the failed mark on \(row.place)")
            }
        }
    }
}

/// Pulse's alert for agents that have waited: everyone who needs you in one card, which stays until it's dismissed
/// or nobody needs you any more.
struct AgentsAlertView: View {
    let rows: [AgentBoard.Row]       // who needs you
    let finished: [AgentBoard.Row]
    let after: String?               // the quiet rule that held it back
    let show: (BreakAgent) -> Void
    let dismiss: () -> Void

    private static let most = 6   // a taller card would run off a small screen

    static func title(_ count: Int) -> String { count == 1 ? "1 agent needs you" : "\(count) agents need you" }

    var body: some View {
        AlertCard(help: "Closes this alert. The agents stay on the rail.", dismiss: dismiss) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
            Text(Self.title(rows.count))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.primary)
            if let after {
                Text(after).font(.body).foregroundStyle(PulsePalette.secondary)
            }
            Divider().padding(.vertical, 4)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                AgentRows(rows: Array(rows.prefix(Self.most)), now: context.date, show: show)
            }
            .padding(.horizontal, -8)
            let more = [rows.count > Self.most ? "\(rows.count - Self.most) more need you" : "",
                        finished.isEmpty ? "" : "\(finished.count) more finished: \(finished.map(\.place).joined(separator: ", "))"]
                .filter { !$0.isEmpty }.joined(separator: ". ")
            if !more.isEmpty {
                Text(more).font(.caption).foregroundStyle(PulsePalette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }
}

/// Settings → Agents. A binding and a flag, not AppState, so it can be rendered on its own.
struct AgentSettingsSection: View {
    @Binding var settings: AgentSettings
    let rexFound: Bool
    @State private var sounds: [String] = []

    var body: some View {
        Section("On the rail") {
            // the caption is outside the switch: a link in a disabled control couldn't be clicked
            LabeledContent {
                Toggle("Show agents on the rail", isOn: Binding(get: { settings.onRail(rexFound: rexFound) }, set: { settings.showOnRail = $0 }))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel("Show agents on the rail")
                    .disabled(!rexFound)
            } label: {
                Text("Show agents on the rail")
                if rexFound {
                    Text("Needs Rex. Shows the agents open in Rex on this Mac and the Macs it connects to: the ring turns orange when one is waiting for you and red when one has failed, with a tick when one has just finished")
                } else {
                    Text("Needs Rex, which Pulse didn't find on this Mac. [Get Rex…](https://www.superlogical.com/rex)")
                }
            }
            Text("While this is on, Pulse reads each pane's label and status line through the rex command all day. It never starts a Rex server and saves nothing to disk. A click on an agent shows its pane in Rex; nothing is answered from Pulse. Rex has its own tab marks, Dock badge, sounds and notifications: Pulse sends no notifications, and holds its own sound and alert while Rex is in front.")
                .font(.caption).foregroundStyle(PulsePalette.secondary)
        }
        Group {
            Section("Sounds and alerts") {
                LabeledContent {
                    SoundChoice(title: "Sound when an agent needs you",
                                sound: Binding(get: { settings.sound.isEmpty ? nil : settings.sound }, set: { settings.sound = $0 ?? "" }),
                                sounds: sounds)
                } label: {
                    Text("Sound when an agent needs you")
                    Text("None by default: Rex can play its own")
                }
                .onAppear { sounds = BatterySounds.all().map(\.name) }
                LabeledContent {
                    Picker("Minutes", selection: $settings.waitMinutes) {
                        ForEach(AgentSettings.waitChoices + (AgentSettings.waitChoices.contains(settings.waitMinutes) ? [] : [settings.waitMinutes]), id: \.self) {
                            Text("\($0) min").tag($0)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!settings.waitAlert)
                    .accessibilityLabel("Minutes an agent waits before the alert")
                    Toggle("Alert after an agent has waited", isOn: $settings.waitAlert)
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Alert after an agent has waited")
                } label: {
                    Text("Alert after an agent has waited")
                    Text("Pulse's own alert in the middle of the screen, once for each wait. It stays until you click Dismiss, or until nobody needs you any more")
                }
            }
            Section("Hold sounds and alerts") {
                Toggle(isOn: $settings.holdWhilePaused) {
                    Text("While breaks are paused")
                    Text("The pause you choose from the cup on the rail")
                }
                .accessibilityLabel("Hold agent sounds and alerts while breaks are paused")
                Toggle(isOn: $settings.holdDuringCalls) {
                    Text("During calls")
                    Text("While an app is using the microphone, and during a Pulse voice call")
                }
                .accessibilityLabel("Hold agent sounds and alerts during calls")
                Toggle("While the screen is locked", isOn: $settings.holdWhileLocked)
                    .accessibilityLabel("Hold agent sounds and alerts while the screen is locked")
                Text("They always wait during a break on screen and while Rex is in front, too. The rail keeps counting. When the hold ends, one alert lists the agents still waiting, not one alert for each.")
                    .font(.caption).foregroundStyle(PulsePalette.secondary)
            }
        }
        .disabled(!rexFound)
    }
}
