import Charts
import SwiftUI

struct ReviewView: View {
	@Bindable var store: JournalStore
	let date: Date
	@State private var review: WeeklyReview?
	@State private var requestID = UUID()

	var body: some View {
		ZStack {
			AppStyle.background.ignoresSafeArea()

			if let review {
				ScrollView {
					VStack(alignment: .leading, spacing: 25) {
						Text(review.weekStart.formatted(.dateTime.month(.abbreviated).day().year()))
							.font(.system(size: 14, weight: .medium))
							.foregroundStyle(AppStyle.secondary)

						Text(review.outcome.isComplete ? review.title : (review.outcome == .cancelled ? "Review paused" : "Review unavailable"))
							.font(.system(size: 27, weight: .semibold))
							.foregroundStyle(.white)
							.fixedSize(horizontal: false, vertical: true)

						if review.recordingMinutes.isEmpty {
							Text("Recording totals unavailable")
								.font(.subheadline)
								.foregroundStyle(AppStyle.secondary)
						} else {
							RecordingMinutesChart(days: review.recordingMinutes)
						}

						if review.outcome.isComplete {
							Text(review.body)
								.font(.system(size: 17))
								.foregroundStyle(Color.white.opacity(0.92))
								.lineSpacing(7)
								.fixedSize(horizontal: false, vertical: true)
						} else {
							Text(failureMessage(review.outcome))
								.foregroundStyle(AppStyle.secondary)
							Button("Retry") { self.review = nil; requestID = UUID() }
								.tint(AppStyle.accent)
						}
					}
					.padding(.horizontal, 24)
					.padding(.top, 12)
					.padding(.bottom, 38)
				}
				.scrollIndicators(.hidden)
			} else {
				VStack(spacing: 15) {
					ProgressView().tint(AppStyle.accent)
					Text("Generating review")
						.font(.system(size: 15, weight: .medium))
						.foregroundStyle(AppStyle.secondary)
				}
			}
		}
		.presentationBackground(AppStyle.background)
		.navigationTitle("Weekly review")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar(.visible, for: .navigationBar)
		.task(id: requestID) {
			let result = await store.weeklyReview(for: date)
			if !Task.isCancelled { review = result }
		}
	}

	private func failureMessage(_ outcome: ModelProcessingOutcome) -> String {
		switch outcome {
		case .failed(let message): message
		case .cancelled: "Try again when recording has finished."
		default: "The on-device model could not finish this review. Your notes are unchanged."
		}
	}
}

private struct RecordingMinutesChart: View {
	let days: [DailyRecordingMinutes]

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Minutes recorded")
				.font(.subheadline.weight(.semibold))
			Text("From available recordings, grouped by recording date.")
				.font(.caption)
				.foregroundStyle(AppStyle.secondary)
			Chart(days) { day in
				BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes recorded", day.minutes))
					.foregroundStyle(AppStyle.accent)
					.accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
					.accessibilityValue("\(day.minutes.formatted(.number.precision(.fractionLength(0...1)))) minutes recorded")
			}
			.chartYScale(domain: 0...max(1, days.map(\.minutes).max() ?? 0))
			.chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
			.chartXAxis {
				AxisMarks(values: days.map(\.date)) {
					AxisValueLabel(format: .dateTime.weekday(.abbreviated))
				}
			}
			.frame(height: 160)
		}
	}
}
