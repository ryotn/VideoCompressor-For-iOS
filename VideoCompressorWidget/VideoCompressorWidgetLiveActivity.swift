import ActivityKit
import WidgetKit
import SwiftUI

struct VideoCompressorWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CompressionAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "film")
                        .foregroundColor(.blue)
                    Text("Compressing...")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "%.0f%%", context.state.progressPercent))
                        .font(.headline)
                        .foregroundColor(.blue)
                }

                Text(context.attributes.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundColor(.secondary)

                ProgressView(value: context.state.progressPercent, total: 100)
                    .tint(.blue)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.8))
            .activitySystemActionForegroundColor(Color.white)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "film")
                        .foregroundColor(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(String(format: "%.0f%%", context.state.progressPercent))
                        .font(.headline)
                        .foregroundColor(.blue)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.attributes.fileName)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundColor(.secondary)
                        ProgressView(value: context.state.progressPercent, total: 100)
                            .tint(.blue)
                    }
                }
            } compactLeading: {
                Image(systemName: "film")
                    .foregroundColor(.blue)
            } compactTrailing: {
                Text(String(format: "%.0f%%", context.state.progressPercent))
                    .font(.caption2)
                    .foregroundColor(.blue)
            } minimal: {
                Image(systemName: "film")
                    .foregroundColor(.blue)
            }
            .widgetURL(URL(string: "videocompressor://"))
            .keylineTint(Color.blue)
        }
    }
}
