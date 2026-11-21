import SwiftUI

struct JourneyCard: View {
    @ObservedObject var scanner: Scanner
    let route: WayfindingJourney
    private var heading: (String, String) {
        if route.stage == .arrived { return (route.stage.rawValue, route.stage.icon) }
        if scanner.isPaused { return ("已暂停", "pause.circle") }
        if scanner.capture == .ready, let cue=scanner.lastSpatialCue {
            switch cue {
            case .stop: return ("先停步", "hand.raised.fill")
            case .turn, .aligned, .face: return ("确认朝向", "arrow.triangle.turn.up.right.diamond")
            case .advance: return ("沿过道慢行", "figure.walk")
            case .found: return ("找到门了", "door.left.hand.open")
            case .wait: return ("查看周围", "viewfinder")
            case .scan: return ("环顾四周", "viewfinder")
            default: break
            }
        }
        switch scanner.capture {
        case .ready: return (route.stage.rawValue, route.stage.icon)
        case .starting: return ("打开相机", "video")
        default: return ("相机状态", "video.slash")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(heading.0).accessibilityIdentifier("routeStage")
            } icon: { Image(systemName: heading.1).foregroundStyle(Palette.accent) }
                .font(.title3.bold()).accessibilityAddTraits(.isHeader)
            GuidanceText(message: scanner.message, feedback: scanner.feedback)
            if scanner.canGuide {
                ForEach(route.choices, id: \.self) { option in
                    Button(option.label) {
                        scanner.selectRouteChoice(option)
                    }.buttonStyle(SignButton(tone: .primary))
                }
                if let action = route.action {
                    Button(action.rawValue) { scanner.routeAction(action) }
                        .buttonStyle(SignButton(tone: .primary)).accessibilityIdentifier("routeConfirm")
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).surface(Palette.paper, radius: Radius.panel)
    }
}

private struct GuidanceText: View {
    let message: String
    @ObservedObject var feedback: Feedback

    var body: some View {
        let cue = Text(message).font(.body).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("feedbackText")
        #if DEBUG && targetEnvironment(simulator)
        if feedback.trace.isEmpty { cue }
        else { cue.accessibilityValue(feedback.trace.joined(separator: "\n")) }
        #else
        cue
        #endif
        if let issue = feedback.issue {
            Label(issue, systemImage: "speaker.badge.exclamationmark").font(.callout)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("voiceIssue")
        }
    }
}

struct JourneyHistory: View {
    let route: WayfindingJourney
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let origin = route.originRoom { LabeledContent("首次门牌", value: origin) }
                if let current = route.currentLevel { LabeledContent("当前楼层", value: current) }
                if let goal = route.site.level { LabeledContent("目标楼层", value: goal) }
                if let zone = route.site.landmark { LabeledContent("目标分区", value: zone) }
                ForEach(Array(route.history.enumerated()), id: \.offset) { _, entry in Text(entry).font(.subheadline).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        } label: {
            Label("沿途记录", systemImage: "list.bullet").foregroundStyle(.primary)
        }.padding(18).surface(Palette.paper, radius: Radius.control)
    }
}
