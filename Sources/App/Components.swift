import SwiftUI

enum AppStyle {
	static let background = Color.black
	static let accent = Color(red: 0.02, green: 0.40, blue: 1.00)
	static let accentSoft = accent.opacity(0.18)
	static let card = Color(red: 0.065, green: 0.075, blue: 0.095)
	static let cardBorder = Color.white.opacity(0.15)
	static let secondary = Color.white.opacity(0.72)
	static let tertiary = Color.white.opacity(0.62)
}

struct AppCard<Content: View>: View {
	@ViewBuilder var content: Content

	var body: some View {
		content
			.padding(.horizontal, 17)
			.padding(.vertical, 20)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(AppStyle.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 13, style: .continuous)
					.stroke(AppStyle.cardBorder, lineWidth: 0.8)
			}
	}
}

struct WaveformView: View {
	let levels: [Double]

	var body: some View {
		GeometryReader { geometry in
			HStack(spacing: 2.25) {
				ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
					Capsule()
						.fill(.white)
						.frame(
							width: max(1.5, (geometry.size.width - CGFloat(levels.count - 1) * 2.25) / CGFloat(levels.count)),
							height: max(2, geometry.size.height * level)
						)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		}
	}
}

extension TimeInterval {
	var clockText: String {
		let seconds = max(0, Int(self.rounded()))
		return String(format: "%d:%02d", seconds / 60, seconds % 60)
	}

	var compactDurationText: String {
		let seconds = max(0, Int(self.rounded()))
		if seconds >= 60 {
			return "\(seconds / 60)m \(seconds % 60)s"
		}
		return "\(seconds)s"
	}
}

extension Date.FormatStyle {
	static var journalHeader: Date.FormatStyle {
		Date.FormatStyle().month(.wide).day().year()
	}

	static var entryHeader: Date.FormatStyle {
		Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().year()
	}
}
