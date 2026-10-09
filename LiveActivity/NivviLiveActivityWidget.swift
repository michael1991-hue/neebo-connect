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
        let base = ActivityConfiguration(for: NivviActivityAttributes.self) { context in
            NivviPresentedActivity(context: context)
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
                    if !context.state.sleep.isEmpty {
                        Text(context.state.sleep)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sleepTint(context.state.sleep))
                    }
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
        return carPlayReady(base)
    }

    private func carPlayReady<T: WidgetConfiguration>(_ configuration: T) -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return configuration.supplementalActivityFamilies([.small])
        }
        return configuration
    }

    @ViewBuilder
    func lockScreen(_ context: ActivityViewContext<NivviActivityAttributes>) -> some View {
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
                readingColumn(icon: "heart.fill", tint: Color(red: 0.93, green: 0.38, blue: 0.42), value: metricNumber(context.state.heartRate), unit: charging(context.state.heartRate) ? "" : "bpm", caption: charging(context.state.heartRate) ? "Charging" : "Heart rate", alert: context.state.alarm == "high" || context.state.alarm == "low")
                Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 52)
                readingColumn(icon: "lungs.fill", tint: Color(red: 0.55, green: 0.78, blue: 0.95), value: metricNumber(context.state.oxygen), unit: charging(context.state.oxygen) ? "" : "%", caption: charging(context.state.oxygen) ? "Charging" : "Oxygen", alert: false)
            }
            if !context.state.sleep.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: sleepIcon(context.state.sleep))
                        .font(.subheadline)
                        .foregroundStyle(sleepTint(context.state.sleep))
                    if context.state.sleep.hasPrefix("Asleep"), context.state.sleepStarted > 0 {
                        Text("Asleep")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(sleepTint(context.state.sleep))
                        Text(timerInterval: Date(timeIntervalSince1970: context.state.sleepStarted)...Date.distantFuture, countsDown: false)
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(sleepTint(context.state.sleep))
                            .lineLimit(1)
                    } else {
                        Text(context.state.sleep)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(sleepTint(context.state.sleep))
                            .lineLimit(1)
                    }
                    if context.state.sleep.hasPrefix("Asleep") {
                        sleepZzz
                    }
                    Spacer(minLength: 0)
                }
            }
            readingStamp(context)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color.black.opacity(0.42))
        .activitySystemActionForegroundColor(.white)
    }

    private var sleepZzz: some View {
        TimelineView(.periodic(from: .now, by: 0.7)) { timeline in
            let step = Int(timeline.date.timeIntervalSince1970 / 0.7) % 3
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text("Z")
                    .font(.subheadline.weight(.bold))
                Text("z")
                    .font(.caption.weight(.bold))
                    .opacity(step > 0 ? 1 : 0.2)
                Text("z")
                    .font(.caption2.weight(.bold))
                    .opacity(step > 1 ? 1 : 0.2)
            }
            .foregroundStyle(Color(red: 0.85, green: 0.82, blue: 1))
        }
    }
    private func sleepTint(_ line: String) -> Color {
        if line.hasPrefix("Asleep") { return Color(red: 0.85, green: 0.82, blue: 1) }
        if line.hasPrefix("Settling") { return Color(red: 0.73, green: 0.78, blue: 0.96) }
        return Color(red: 0.45, green: 0.86, blue: 0.74)
    }
    private func sleepIcon(_ line: String) -> String {
        line.hasPrefix("Asleep") || line.hasPrefix("Settling") ? "moon.fill" : "figure.walk"
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
        if charging(trimmed) { return "Charging" }
        if trimmed.isEmpty || trimmed == "—" || trimmed.localizedCaseInsensitiveContains("no reading") { return "—" }
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        return number.isEmpty ? "—" : String(number)
    }

    @ViewBuilder
    private func readingStamp(_ context: ActivityViewContext<NivviActivityAttributes>) -> some View {
        if context.state.measuredAt > 0 {
            (Text("Last reading · ") + Text(Date(timeIntervalSince1970: context.state.measuredAt), style: .relative))
                .font(.caption.weight(.medium))
                .foregroundStyle(activityIsStale(context) ? Color(red: 1, green: 0.62, blue: 0.28) : Color.white.opacity(0.62))
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            Text("No reading yet")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(maxWidth: .infinity)
        }
    }

    private func bannerStatus(_ context: ActivityViewContext<NivviActivityAttributes>) -> (title: String, color: Color) {
        let mint = Color(red: 0.45, green: 0.86, blue: 0.74)
        let caution = Color(red: 1, green: 0.62, blue: 0.28)
        if charging(context.state.heartRate) { return ("Charging", Color(red: 1, green: 0.72, blue: 0.28)) }
        if activityIsStale(context) { return ("Delayed", caution) }
        if context.state.alarm == "removed" { return ("Removed", caution) }
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

    private func charging(_ raw: String) -> Bool {
        raw.localizedCaseInsensitiveContains("charg")
    }

    private func readingsDelayed(_ context: ActivityViewContext<NivviActivityAttributes>) -> Bool {
        activityIsStale(context)
    }

    private func activityIsStale(_ context: ActivityViewContext<NivviActivityAttributes>) -> Bool {
        if #available(iOS 16.2, *) {
            return context.isStale || context.state.stale
        }
        return context.state.stale
    }
}

struct NivviPresentedActivity: View {
    let context: ActivityViewContext<NivviActivityAttributes>

    var body: some View {
        if #available(iOS 18.0, *) {
            NivviFamilyActivity(context: context)
        } else {
            NivviLiveActivityWidget().lockScreen(context)
        }
    }
}

@available(iOS 18.0, *)
struct NivviFamilyActivity: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<NivviActivityAttributes>

    var body: some View {
        if activityFamily == .small {
            NivviCarPlayCard(context: context)
        } else {
            NivviLiveActivityWidget().lockScreen(context)
        }
    }
}

/// Glance layout for the CarPlay dashboard. The system already prints “Nivvi” above this.
struct NivviCarPlayCard: View {
    let context: ActivityViewContext<NivviActivityAttributes>

    var body: some View {
        let alert = context.state.alarm == "high" || context.state.alarm == "low"
        let charging = context.state.heartRate.localizedCaseInsensitiveContains("charg")
        let delayed = context.state.stale || context.isStale
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .foregroundStyle(alert ? Color.red : Color.pink)
                Text(number(context.state.heartRate))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(alert ? Color.red : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !charging {
                    Text("bpm")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !charging, number(context.state.oxygen) != "—" {
                    Text(number(context.state.oxygen))
                        .font(.title2.bold())
                        .foregroundStyle(Color.primary)
                    Text("%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(line(alert: alert, charging: charging, delayed: delayed))
                .font(.caption.weight(.semibold))
                .foregroundStyle(alert || delayed ? Color.orange : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func line(alert: Bool, charging: Bool, delayed: Bool) -> String {
        let name = context.attributes.title
        if charging { return "Charging" }
        if context.state.alarm == "high" { return "\(name) · High" }
        if context.state.alarm == "low" { return "\(name) · Low" }
        if context.state.alarm == "removed" { return "\(name) · Band off" }
        if delayed { return "\(name) · Delayed" }
        if !context.state.sleep.isEmpty { return "\(name) · \(context.state.sleep)" }
        return name
    }

    private func number(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.localizedCaseInsensitiveContains("charg") { return "Charging" }
        if trimmed.isEmpty || trimmed == "—" || trimmed.localizedCaseInsensitiveContains("no reading") { return "—" }
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        return digits.isEmpty ? "—" : String(digits)
    }
}
