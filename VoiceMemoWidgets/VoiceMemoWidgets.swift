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
		.description("Start a voice memo.")
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
			HStack(spacing: 13) {
				VoiceMemoAppIcon(size: 38)

				VStack(alignment: .leading, spacing: 3) {
					Text(context.state.locationName)
						.font(.headline)
						.lineLimit(1)
					Text(context.attributes.startedAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				Spacer()

				RecordingElapsedTime(state: context.state)
					.font(.title3.weight(.semibold))
			}
			.padding(.horizontal, 5)
			.activityBackgroundTint(.black)
			.activitySystemActionForegroundColor(.white)
		} dynamicIsland: { context in
			DynamicIsland {
				DynamicIslandExpandedRegion(.leading) {
					VoiceMemoAppIcon(size: 32)
				}
				DynamicIslandExpandedRegion(.center) {
					VStack(alignment: .leading, spacing: 2) {
						Text(context.state.locationName)
							.font(.headline)
							.lineLimit(1)
						Text(context.state.isPaused ? "Paused" : "Recording")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				DynamicIslandExpandedRegion(.trailing) {
					RecordingElapsedTime(state: context.state)
						.monospacedDigit()
				}
			} compactLeading: {
				VoiceMemoAppIcon(size: 22)
			} compactTrailing: {
				RecordingElapsedTime(state: context.state)
					.monospacedDigit()
					.frame(width: 52)
			} minimal: {
				VoiceMemoAppIcon(size: 22)
			}
			.widgetURL(URL(string: "myvoicememo://record"))
		}
	}
}

private struct RecordingElapsedTime: View {
	let state: RecordingActivityAttributes.ContentState

	var body: some View {
		Group {
			if let resumedAt = state.resumedAt {
				Text(
					.currentDate,
					format: .stopwatch(
						startingAt: resumedAt.addingTimeInterval(-state.elapsed),
						showsHours: false,
						maxFieldCount: 2,
						maxPrecision: .seconds(1)
					)
				)
			} else {
				Text(pausedElapsedText)
			}
		}
		.monospacedDigit()
	}

	private var pausedElapsedText: String {
		let seconds = max(0, Int(state.elapsed))
		return String(format: "%d:%02d", seconds / 60, seconds % 60)
	}
}

private struct VoiceMemoAppIcon: View {
	let size: CGFloat

	private let rows = [3, 5, 7, 8, 8, 8, 7, 5, 3]

	var body: some View {
		Canvas { context, canvasSize in
			let length = min(canvasSize.width, canvasSize.height)
			let iconRect = CGRect(x: 0, y: 0, width: length, height: length)
			context.fill(
				Path(roundedRect: iconRect, cornerRadius: length * 0.22),
				with: .color(.white)
			)

			let spacing = length * 0.09
			let diameter = max(1, length * 0.043)
			for (rowIndex, count) in rows.enumerated() {
				let rowWidth = CGFloat(count - 1) * spacing
				let startX = (length - rowWidth) / 2
				let y = length * 0.22 + CGFloat(rowIndex) * length * 0.07
				for column in 0..<count {
					let x = startX + CGFloat(column) * spacing
					let dot = CGRect(
						x: x - diameter / 2,
						y: y - diameter / 2,
						width: diameter,
						height: diameter
					)
					context.fill(Path(ellipseIn: dot), with: .color(.black))
				}
			}
		}
		.frame(width: size, height: size)
	}
}
