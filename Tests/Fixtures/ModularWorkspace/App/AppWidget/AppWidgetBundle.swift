import SwiftUI
import WidgetKit

@main
struct AppWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Status", provider: StatusProvider()) { _ in
            Image("widget_icon")
        }
    }
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) { completion(SimpleEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry(date: .now)], policy: .never))
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
}
