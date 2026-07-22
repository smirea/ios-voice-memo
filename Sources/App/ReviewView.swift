import SwiftUI

struct ReviewView: View {
	@Bindable var store: JournalStore
	let date: Date
	let onClose: () -> Void
	@State private var review: WeeklyReview?

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			if let review {
				ScrollView {
					VStack(alignment: .leading, spacing: 25) {
						HStack {
							InvisibleCloseControl(action: onClose)
								.offset(x: -14)
							Spacer()
							Text("Review")
								.font(.system(size: 11))
								.foregroundStyle(Color.white.opacity(0.76))
							Spacer()
							Color.clear.frame(width: 30, height: 44)
						}

						Text(review.weekStart.formatted(.dateTime.month(.abbreviated).day()))
							.font(.system(size: 9))
							.foregroundStyle(SlateStyle.tertiary)

						Text(review.title)
							.font(.system(size: 25, weight: .regular))
							.foregroundStyle(.white)
							.fixedSize(horizontal: false, vertical: true)

						TrendGraph(values: review.trend)
							.frame(height: 54)
							.padding(.vertical, 4)

						Text(review.body)
							.font(.system(size: 17))
							.foregroundStyle(Color.white.opacity(0.84))
							.lineSpacing(7)
							.fixedSize(horizontal: false, vertical: true)

						FlowLayout(spacing: 6) {
							ForEach(review.tags, id: \.self) { SlateTag(text: $0) }
						}
					}
					.padding(.horizontal, 31)
					.padding(.bottom, 38)
				}
				.scrollIndicators(.hidden)
			} else {
				VStack(spacing: 15) {
					ProgressView().tint(SlateStyle.accent)
					Text("Reading the week back…")
						.font(.system(size: 12))
						.foregroundStyle(SlateStyle.secondary)
				}
			}
		}
		.presentationBackground(.black)
		.swipeBack(action: onClose)
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
				.stroke(SlateStyle.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

				ForEach(Array(points.enumerated()), id: \.offset) { _, point in
					Circle()
						.fill(SlateStyle.accent)
						.frame(width: 4, height: 4)
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
