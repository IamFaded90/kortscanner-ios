import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit

struct SnapshotConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Samlingsøjebliksbillede"
    static var description = IntentDescription("Manuelt øjebliksbillede uden App Groups. Opdatér tallene ved at redigere widgetten.")
    @Parameter(title: "Samlet værdi i DKK", default: 0) var amount: Double
    @Parameter(title: "Seneste kort", default: "") var latestName: String
}
struct CollectionEntry: TimelineEntry {
    var date: Date
    var configuration: SnapshotConfiguration
}
struct CollectionProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CollectionEntry { CollectionEntry(date: Date(), configuration: SnapshotConfiguration()) }
    func snapshot(for configuration: SnapshotConfiguration, in context: Context) async -> CollectionEntry { CollectionEntry(date: Date(), configuration: configuration) }
    func timeline(for configuration: SnapshotConfiguration, in context: Context) async -> Timeline<CollectionEntry> {
        Timeline(entries: [CollectionEntry(date: Date(), configuration: configuration)], policy: .never)
    }
}
struct CollectionWidgetView: View {
    let entry: CollectionEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Kortscanner", systemImage: "rectangle.stack.fill").font(.headline).foregroundStyle(.yellow)
            if entry.configuration.latestName.isEmpty {
                Text("Redigér widgetten").font(.headline)
                Text("Indtast værdi og seneste kort fra din samling.").font(.caption)
            } else {
                Text(entry.configuration.amount.formatted(.currency(code: "DKK").locale(Locale(identifier: "da_DK")))).font(.title2.bold()).minimumScaleFactor(0.6).lineLimit(1)
                Text(entry.configuration.latestName).font(.subheadline).lineLimit(2)
                Text("Manuelt øjebliksbillede").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.containerBackground(for: .widget) { Color(red: 0.025, green: 0.045, blue: 0.09) }.foregroundStyle(.white)
            .widgetURL(URL(string: "kortscanner://samling"))
    }
}
struct CollectionWidget: Widget {
    let kind = "KortscannerCollection"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SnapshotConfiguration.self, provider: CollectionProvider()) { entry in CollectionWidgetView(entry: entry) }
            .configurationDisplayName("Kortscanner · øjebliksbillede")
            .description("Værdi og seneste kort, angivet manuelt. Ingen delt appcontainer.")
            .supportedFamilies([.systemSmall, .systemMedium])
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
        CollectionWidget()
        BatchActivityWidget()
    }
}
