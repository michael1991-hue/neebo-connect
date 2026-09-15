import SwiftUI
import WidgetKit
import ActivityKit

@main
struct NivviWidgetBundle: WidgetBundle {
    var body: some Widget {
        NivviLiveActivityWidget()
    }
}

struct NivviLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NivviActivityAttributes.self) { context in
            lockScreen(context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HR").font(.caption2).foregroundStyle(.secondary)
                        Text(context.state.heartRate).font(.title3.bold())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("O₂").font(.caption2).foregroundStyle(.secondary)
                        Text(context.state.oxygen).font(.title3.bold())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.connection)
                        .font(.caption)
                    if !context.state.nurseryHint.isEmpty {
                        Text(context.state.nurseryHint).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
            } compactTrailing: {
                Text(context.state.heartRate).font(.caption.bold())
            } minimal: {
                Image(systemName: "heart.fill")
            }
        }
    }

    @ViewBuilder
    private func lockScreen(_ context: ActivityViewContext<NivviActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.fill").foregroundStyle(.pink).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.title).font(.caption.weight(.semibold))
                Text(context.state.heartRate).font(.title2.bold())
                Text("O₂ \(context.state.oxygen) · \(context.state.connection)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !context.state.nurseryHint.isEmpty {
                    Text(context.state.nurseryHint).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .activityBackgroundTint(Color.black.opacity(0.35))
        .activitySystemActionForegroundColor(.white)
    }
}
