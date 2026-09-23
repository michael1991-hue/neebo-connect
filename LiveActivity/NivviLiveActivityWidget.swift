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
                    Text(lockCaption(context))
                        .font(.caption)
                    if !context.state.nurseryHint.isEmpty && !readingsDelayed(context) {
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
        let status = bannerStatus(context)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(context.attributes.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(status.color)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            HStack(alignment: .center, spacing: 0) {
                readingColumn(icon: "heart.fill", tint: Color(red: 0.93, green: 0.38, blue: 0.42), value: metricNumber(context.state.heartRate), unit: "bpm", caption: "Heart rate", alert: context.state.alarm == "high" || context.state.alarm == "low")
                Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 52)
                readingColumn(icon: "lungs.fill", tint: Color(red: 0.55, green: 0.78, blue: 0.95), value: metricNumber(context.state.oxygen), unit: "%", caption: "Oxygen", alert: false)
            }
            Text(readingStamp(context))
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color.black.opacity(0.42))
        .activitySystemActionForegroundColor(.white)
    }

    private func readingColumn(icon: String, tint: Color, value: String, unit: String, caption: String, alert: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(alert ? Color(red: 1, green: 0.45, blue: 0.4) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: 48, alignment: .leading)
                Text(unit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.62))
                .padding(.leading, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private func metricNumber(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" || trimmed.localizedCaseInsensitiveContains("no reading") { return "—" }
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        return number.isEmpty ? "—" : String(number)
    }

    private func readingStamp(_ context: ActivityViewContext<NivviActivityAttributes>) -> String {
        guard context.state.measuredAt > 0 else { return "No reading yet" }
        let time = Date(timeIntervalSince1970: context.state.measuredAt)
        return "Last reading · " + time.formatted(Date.FormatStyle().hour().minute().second())
    }

    private func bannerStatus(_ context: ActivityViewContext<NivviActivityAttributes>) -> (title: String, color: Color) {
        let mint = Color(red: 0.45, green: 0.86, blue: 0.74)
        let caution = Color(red: 1, green: 0.62, blue: 0.28)
        if context.state.stale { return ("Delayed", caution) }
        if metricNumber(context.state.heartRate) == "—" { return ("Waiting", caution) }
        let connection = context.state.connection.lowercased()
        if connection.contains("not connected") || connection.contains("disconnect") || connection.contains("bluetooth") {
            return ("Disconnected", caution)
        }
        if connection.contains("receiving") || connection.contains("live") || connection.contains("wi-fi") || connection.contains("wi‑fi") || connection.contains("family") {
            return ("Receiving", mint)
        }
        return ("Waiting", caution)
    }

    private func lockCaption(_ context: ActivityViewContext<NivviActivityAttributes>) -> String {
        if readingsDelayed(context) { return "Readings delayed" }
        if context.state.measuredAt > 0 {
            let time = Date(timeIntervalSince1970: context.state.measuredAt)
            return "Measured " + time.formatted(Date.FormatStyle().hour().minute().second())
        }
        return context.state.connection
    }

    private func readingsDelayed(_ context: ActivityViewContext<NivviActivityAttributes>) -> Bool {
        context.state.stale
    }
}
