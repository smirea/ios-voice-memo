import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VoiceMemoWidgets: WidgetBundle {
	var body: some Widget {
		StartRecordingWidget()
		RecordingLiveActivity()
	}
}

struct StartRecordingWidget: Widget {
	let kind = "StartRecordingWidget"

	var body: some WidgetConfiguration {
		StaticConfiguration(kind: kind, provider: RecordingWidgetProvider()) { _ in
			Link(destination: URL(string: "myvoicememo://record")!) {
				Image(systemName: "mic.fill")
					.font(.title3)
					.widgetAccentable()
			}
			.containerBackground(.black, for: .widget)
		}
		.configurationDisplayName("New recording")
		.description("Start a private voice journal entry.")
		.supportedFamilies([.accessoryCircular])
	}
}

struct RecordingWidgetEntry: TimelineEntry {
	let date: Date
}

struct RecordingWidgetProvider: TimelineProvider {
	func placeholder(in context: Context) -> RecordingWidgetEntry {
		RecordingWidgetEntry(date: .now)
	}

	func getSnapshot(in context: Context, completion: @escaping (RecordingWidgetEntry) -> Void) {
		completion(RecordingWidgetEntry(date: .now))
	}

	func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingWidgetEntry>) -> Void) {
		completion(Timeline(entries: [RecordingWidgetEntry(date: .now)], policy: .never))
	}
}

struct RecordingLiveActivity: Widget {
	var body: some WidgetConfiguration {
		ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
			HStack(spacing: 12) {
				Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
					.font(.headline)
				Text(context.state.isPaused ? "Paused" : "Recording")
					.font(.headline)
				Spacer()
				Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
					.monospacedDigit()
			}
			.padding(.horizontal, 4)
			.activityBackgroundTint(.black)
			.activitySystemActionForegroundColor(.white)
		} dynamicIsland: { context in
			DynamicIsland {
				DynamicIslandExpandedRegion(.leading) {
					Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
				}
				DynamicIslandExpandedRegion(.center) {
					Text(context.state.isPaused ? "Paused" : "Recording")
						.font(.headline)
				}
				DynamicIslandExpandedRegion(.trailing) {
					Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
						.monospacedDigit()
				}
			} compactLeading: {
				Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
			} compactTrailing: {
				Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
					.monospacedDigit()
					.frame(width: 52)
			} minimal: {
				Image(systemName: "waveform")
			}
			.widgetURL(URL(string: "myvoicememo://record"))
		}
	}
}
