import SwiftUI

struct ReviewView: View {
	@Bindable var store: JournalStore
	let date: Date
	@State private var review: WeeklyReview?

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			if let review {
				ScrollView {
					VStack(alignment: .leading, spacing: 25) {
						Text(review.weekStart.formatted(.dateTime.month(.abbreviated).day().year()))
							.font(.system(size: 14, weight: .medium))
							.foregroundStyle(AppStyle.secondary)

						Text(review.title)
							.font(.system(size: 27, weight: .semibold))
							.foregroundStyle(.white)
							.fixedSize(horizontal: false, vertical: true)

						TrendGraph(values: review.trend)
							.frame(height: 54)
							.padding(.vertical, 4)

						Text(review.body)
							.font(.system(size: 17))
							.foregroundStyle(Color.white.opacity(0.92))
							.lineSpacing(7)
							.fixedSize(horizontal: false, vertical: true)
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
		.presentationBackground(.black)
		.navigationTitle("Weekly review")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar(.visible, for: .navigationBar)
		.task(id: date) { review = await store.weeklyReview(for: date) }
	}
}

private struct TrendGraph: View {
	let values: [Double]

	var body: some View {
		GeometryReader { geometry in
			let points = points(in: geometry.size)
			ZStack {
				Path { path in
					guard let first = points.first else { return }
					path.move(to: first)
					for point in points.dropFirst() { path.addLine(to: point) }
				}
				.stroke(AppStyle.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

				ForEach(Array(points.enumerated()), id: \.offset) { _, point in
					Circle()
						.fill(AppStyle.accent)
						.frame(width: 6, height: 6)
						.position(point)
				}
			}
		}
	}

	private func points(in size: CGSize) -> [CGPoint] {
		guard !values.isEmpty else { return [] }
		if values.count == 1 { return [CGPoint(x: size.width / 2, y: size.height / 2)] }
		return values.enumerated().map { index, value in
			CGPoint(
				x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
				y: size.height - CGFloat(max(0, min(1, value))) * size.height
			)
		}
	}
}
