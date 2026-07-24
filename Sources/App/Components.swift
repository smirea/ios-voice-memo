import SwiftUI
import UIKit

enum AppStyle {
	static let background = Color.black
	static let accent = Color(red: 0.02, green: 0.40, blue: 1.00)
	static let secondary = Color.white.opacity(0.72)
	static let tertiary = Color.white.opacity(0.62)
}

struct SummaryToPopup: View {
	let text: String
	var lineLimit = 4
	var accessibilityName = "Text"

	var body: some View {
		NavigationLink {
			FullScreenTextReader(text: text, accessibilityName: accessibilityName)
		} label: {
			Text(text)
				.font(.system(size: 16))
				.foregroundStyle(Color.white.opacity(0.90))
				.lineSpacing(5)
				.lineLimit(lineLimit)
				.truncationMode(.tail)
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityHint("Opens full screen")
	}
}

private struct FullScreenTextReader: View {
	let text: String
	let accessibilityName: String
	@Environment(\.dismiss) private var dismiss
	@State private var didCopy = false

	var body: some View {
		ZStack {
			AppStyle.background.ignoresSafeArea()

			SelectableTextView(text: text, accessibilityName: accessibilityName)
		}
		.safeAreaInset(edge: .top, spacing: 0) {
			HStack {
				Spacer()
				closeButton
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 8)
		}
		.safeAreaInset(edge: .bottom, spacing: 0) {
			HStack {
				copyButton
				Spacer()
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 10)
		}
		.toolbar(.hidden, for: .navigationBar)
		.navigationBarBackButtonHidden(true)
		.background(NativeBackSwipeEnabler())
	}

	private var closeButton: some View {
		Button {
			dismiss()
		} label: {
			Image(systemName: "xmark")
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 46, height: 46)
				.contentShape(Circle())
		}
		.buttonStyle(.plain)
		.glassEffect(.regular.interactive(), in: Circle())
		.accessibilityLabel("Close")
	}

	private var copyButton: some View {
		Button {
			UIPasteboard.general.string = text
			withAnimation(.easeOut(duration: 0.18)) {
				didCopy = true
			}
		} label: {
			Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(.white)
				.padding(.horizontal, 16)
				.frame(height: 46)
		}
		.buttonStyle(.plain)
		.glassEffect(.regular.interactive(), in: Capsule())
		.accessibilityLabel(didCopy ? "Copied" : "Copy \(accessibilityName.lowercased())")
	}
}

private struct SelectableTextView: UIViewRepresentable {
	let text: String
	let accessibilityName: String

	func makeUIView(context: Context) -> UITextView {
		let textView = UITextView()
		textView.isEditable = false
		textView.isSelectable = true
		textView.backgroundColor = .clear
		textView.showsVerticalScrollIndicator = false
		textView.adjustsFontForContentSizeCategory = true
		textView.textContainerInset = UIEdgeInsets(top: 24, left: 19, bottom: 24, right: 19)
		textView.accessibilityLabel = accessibilityName
		applyText(to: textView)
		return textView
	}

	func updateUIView(_ textView: UITextView, context: Context) {
		guard textView.text != text else { return }
		applyText(to: textView)
	}

	private func applyText(to textView: UITextView) {
		let paragraph = NSMutableParagraphStyle()
		paragraph.lineSpacing = 6
		textView.attributedText = NSAttributedString(
			string: text,
			attributes: [
				.font: UIFont.preferredFont(forTextStyle: .body),
				.foregroundColor: UIColor.white.withAlphaComponent(0.94),
				.paragraphStyle: paragraph
			]
		)
	}
}

struct NativeBackSwipeEnabler: UIViewControllerRepresentable {
	func makeUIViewController(context: Context) -> Controller {
		Controller()
	}

	func updateUIViewController(_ controller: Controller, context: Context) {}

	final class Controller: UIViewController {
		override func viewDidAppear(_ animated: Bool) {
			super.viewDidAppear(animated)
			guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
			gesture.delegate = nil
			gesture.isEnabled = true
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
}

extension Date {
	var compactHeaderText: String {
		let formatter = DateFormatter()
		formatter.locale = .current
		formatter.dateFormat = Calendar.current.component(.year, from: self)
			== Calendar.current.component(.year, from: .now)
			? "EEE MMM d"
			: "EEE MMM d yyyy"
		return formatter.string(from: self)
	}
}
