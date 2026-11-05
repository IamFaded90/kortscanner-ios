import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit

struct ScanCardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "Kortscanner.ScanControl") {
            ControlWidgetButton(action: ScanCardIntent()) {
                Label("Scan et kort", systemImage: "viewfinder")
            }
        }
        .displayName("Scan et kort")
        .description("Åbn Kortscanner-kameraet fra Kontrolcenter.")
    }
}
struct BatchActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScanActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Kortscanner · batch", systemImage: "viewfinder").font(.headline)
                    Spacer()
                    Text("\(context.state.count) kort").bold()
                }
                Text(context.state.phase)
                Text(context.state.totalDKK.formatted(.currency(code: "DKK").locale(Locale(identifier: "da_DK")))).font(.title2.bold())
                if !context.state.latestName.isEmpty { Text("Senest: \(context.state.latestName)").font(.caption) }
            }.padding(18).activityBackgroundTint(.black.opacity(0.9)).activitySystemActionForegroundColor(.yellow)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Batch", systemImage: "viewfinder") }
                DynamicIslandExpandedRegion(.trailing) { Text("\(context.state.count) kort") }
                DynamicIslandExpandedRegion(.bottom) { Text(context.state.phase).font(.headline) }
            } compactLeading: { Image(systemName: "viewfinder").foregroundStyle(.yellow) }
              compactTrailing: { Text("\(context.state.count)") }
              minimal: { Image(systemName: "viewfinder").foregroundStyle(.yellow) }
              .widgetURL(URL(string: "kortscanner://scan")).keylineTint(.yellow)
        }
    }
}
@main
struct KortscannerWidgetBundle: WidgetBundle {
    var body: some Widget {
        BatchActivityWidget()
        ScanCardControl()
    }
}
