import SwiftUI

enum SlateStyle {
	static let background = Color.black
	static let accent = Color(red: 0.04, green: 0.39, blue: 0.98)
	static let accentSoft = accent.opacity(0.14)
	static let card = Color.white.opacity(0.035)
	static let cardBorder = Color.white.opacity(0.075)
	static let secondary = Color.white.opacity(0.38)
	static let tertiary = Color.white.opacity(0.20)
}

struct SlateCard<Content: View>: View {
	@ViewBuilder var content: Content

	var body: some View {
		content
			.padding(.horizontal, 17)
			.padding(.vertical, 20)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(SlateStyle.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 13, style: .continuous)
					.stroke(SlateStyle.cardBorder, lineWidth: 0.7)
			}
	}
}

struct SlateTag: View {
	let text: String

	var body: some View {
		Text(text)
			.font(.system(size: 9, weight: .regular))
			.foregroundStyle(Color.white.opacity(0.62))
			.lineLimit(1)
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(SlateStyle.accent.opacity(0.08), in: Capsule())
			.overlay {
				Capsule().stroke(SlateStyle.accent.opacity(0.30), lineWidth: 0.7)
			}
	}
}

struct CloseControl: View {
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: "xmark")
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(Color.white.opacity(0.72))
				.frame(width: 44, height: 44)
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Close")
	}
}

struct InvisibleCloseControl: View {
	let action: () -> Void

	var body: some View {
		Button(action: action) { Color.clear.frame(width: 44, height: 44) }
			.buttonStyle(.plain)
			.accessibilityLabel("Close")
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

struct ProcessingOverlay: View {
	let message: String

	var body: some View {
		ZStack {
			Color.black.opacity(0.82).ignoresSafeArea()
			VStack(spacing: 18) {
				ProgressView().tint(SlateStyle.accent)
				Text(message)
					.font(.system(size: 13))
					.foregroundStyle(Color.white.opacity(0.62))
			}
		}
	}
}

private struct SwipeBackModifier: ViewModifier {
	let action: () -> Void
	@GestureState private var translation: CGFloat = 0

	func body(content: Content) -> some View {
		content
			.offset(x: max(0, translation))
			.opacity(1 - min(0.22, max(0, translation) / 900))
			.simultaneousGesture(
				DragGesture(minimumDistance: 24)
					.updating($translation) { value, state, _ in
						guard value.translation.width > 0,
							abs(value.translation.width) > abs(value.translation.height) * 1.25
						else { return }
						state = value.translation.width
					}
					.onEnded { value in
						guard value.translation.width > 90,
							abs(value.translation.width) > abs(value.translation.height) * 1.25
						else { return }
						action()
					}
			)
			.accessibilityAction(.escape, action)
	}
}

extension View {
	func swipeBack(action: @escaping () -> Void) -> some View {
		modifier(SwipeBackModifier(action: action))
	}
}

struct FlowLayout: Layout {
	var spacing: CGFloat = 6

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? 0
		var x: CGFloat = 0
		var y: CGFloat = 0
		var rowHeight: CGFloat = 0
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if x > 0, x + size.width > width {
				x = 0
				y += rowHeight + spacing
				rowHeight = 0
			}
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
		}
		return CGSize(width: width, height: y + rowHeight)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var x = bounds.minX
		var y = bounds.minY
		var rowHeight: CGFloat = 0
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if x > bounds.minX, x + size.width > bounds.maxX {
				x = bounds.minX
				y += rowHeight + spacing
				rowHeight = 0
			}
			subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
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
	static var slateHeader: Date.FormatStyle {
		Date.FormatStyle().month(.wide).day().year()
	}

	static var slateEntryHeader: Date.FormatStyle {
		Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().year()
	}
}
