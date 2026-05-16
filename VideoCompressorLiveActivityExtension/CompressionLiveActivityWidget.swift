import ActivityKit
import SwiftUI
import WidgetKit

struct CompressionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CompressionActivity.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text("動画圧縮中")
                    .font(.headline)
                Text(context.attributes.sourceFileName)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                ProgressView(value: context.state.progress)
                Text("\(Int(context.state.progress * 100))%")
                    .font(.title3)
                    .bold()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "video")
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("圧縮中")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .bold()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                }
            } compactLeading: {
                Image(systemName: "video")
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
            } minimal: {
                Image(systemName: "video.fill")
            }
        }
    }
}
