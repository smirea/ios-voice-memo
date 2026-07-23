import MapKit
import SwiftUI
import UIKit

struct EntryView: View {
	@Bindable var store: JournalStore
	let entry: JournalEntry

	private var currentEntry: JournalEntry {
		store.entry(id: entry.id) ?? entry
	}

	private var headerDate: String {
		let formatter = DateFormatter()
		formatter.locale = .current
		let currentYear = Calendar.current.component(.year, from: .now)
		let entryYear = Calendar.current.component(.year, from: currentEntry.createdAt)
		formatter.dateFormat = entryYear == currentYear ? "EEE MMM d" : "EEE MMM d yyyy"
		return formatter.string(from: currentEntry.createdAt)
	}

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			ScrollView {
				VStack(alignment: .leading, spacing: 32) {
					HStack(alignment: .firstTextBaseline, spacing: 16) {
						Text(currentEntry.location?.displayName ?? "Voice memo")
							.font(.system(size: 25, weight: .semibold))
							.foregroundStyle(.white)
							.lineLimit(1)
							.truncationMode(.tail)
						Spacer(minLength: 0)
						Text(headerDate)
							.font(.system(size: 25, weight: .semibold))
							.foregroundStyle(.white)
							.lineLimit(1)
							.fixedSize(horizontal: true, vertical: false)
							.layoutPriority(1)
					}
					.padding(.top, 10)

					if let phase = store.processingPhase(for: entry.id) {
						EntryProcessingStatusView(phase: phase)
							.transition(.move(edge: .top).combined(with: .opacity))
					}

					VStack(alignment: .leading, spacing: 16) {
						Text(currentEntry.headline)
							.font(.system(size: 22, weight: .semibold))
							.foregroundStyle(.white)
							.fixedSize(horizontal: false, vertical: true)

						VStack(alignment: .leading, spacing: 13) {
							ForEach(currentEntry.observations.filter { $0 != currentEntry.headline }, id: \.self) { observation in
								Text(observation)
									.font(.system(size: 17, weight: .regular))
									.foregroundStyle(Color.white.opacity(0.92))
									.lineSpacing(4)
									.fixedSize(horizontal: false, vertical: true)
							}
						}

						if let model = currentEntry.summaryModel {
							ModelAttribution(model: model)
						}

						if !currentEntry.tags.isEmpty {
							FlowLayout(spacing: 7) {
								ForEach(currentEntry.tags, id: \.self) { TagPill(text: $0) }
							}
						}
					}

					if store.settings.showTranscripts, !currentEntry.transcript.isEmpty {
						VStack(alignment: .leading, spacing: 12) {
							ExpandableTranscript(text: currentEntry.transcript)
								.contentTransition(.opacity)

							if let model = currentEntry.transcriptModel {
								ModelAttribution(model: model)
							}
						}
					}

					if let location = currentEntry.location {
						EntryLocationMap(location: location)
							.transition(.move(edge: .bottom).combined(with: .opacity))
					}
				}
				.padding(.horizontal, 24)
				.padding(.bottom, 40)
			}
			.scrollIndicators(.hidden)
		}
		.presentationBackground(.black)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar(.visible, for: .navigationBar)
		.animation(.easeOut(duration: 0.22), value: store.processingPhase(for: entry.id))
		.animation(.easeOut(duration: 0.28), value: currentEntry.location)
	}
}

private struct ModelAttribution: View {
	let model: String

	var body: some View {
		Text(model)
			.font(.system(size: 12, weight: .medium))
			.foregroundStyle(AppStyle.tertiary)
			.frame(maxWidth: .infinity, alignment: .trailing)
	}
}

private struct ExpandableTranscript: View {
	let text: String
	@State private var isExpanded = false
	@State private var availableWidth: CGFloat = 0

	private var isTruncated: Bool {
		guard availableWidth > 32 else { return false }
		return textLineCount(width: availableWidth - 32) > 4
	}

	var body: some View {
		Text(text)
			.font(.system(size: 16))
			.foregroundStyle(Color.white.opacity(0.90))
			.lineSpacing(5)
			.lineLimit(isExpanded ? nil : 4)
			.fixedSize(horizontal: false, vertical: true)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(isTruncated ? 16 : 0)
			.padding(.bottom, isTruncated ? 28 : 0)
			.background(isTruncated ? AppStyle.card : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			.overlay {
				if isTruncated {
					RoundedRectangle(cornerRadius: 14, style: .continuous)
						.stroke(AppStyle.cardBorder, lineWidth: 0.8)
				}
			}
			.overlay(alignment: .bottomTrailing) {
				if isTruncated {
					Button {
						withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
					} label: {
						Image(systemName: isExpanded ? "chevron.up.circle.fill" : "ellipsis.circle.fill")
							.font(.system(size: 22))
							.foregroundStyle(AppStyle.accent)
							.frame(width: 44, height: 44)
					}
					.buttonStyle(.plain)
					.accessibilityLabel(isExpanded ? "Collapse transcript" : "Expand transcript")
				}
			}
			.textSelection(.enabled)
			.background {
				GeometryReader { proxy in
					Color.clear
						.onAppear { availableWidth = proxy.size.width }
						.onChange(of: proxy.size.width) { _, width in
							availableWidth = width
						}
				}
			}
	}

	private func textLineCount(width: CGFloat) -> Int {
		let textStorage = NSTextStorage(
			string: text,
			attributes: [.font: UIFont.systemFont(ofSize: 16)]
		)
		let layoutManager = NSLayoutManager()
		let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
		textContainer.lineFragmentPadding = 0
		textContainer.maximumNumberOfLines = 0
		layoutManager.addTextContainer(textContainer)
		textStorage.addLayoutManager(layoutManager)
		layoutManager.ensureLayout(for: textContainer)

		var lineCount = 0
		var glyphIndex = 0
		while glyphIndex < layoutManager.numberOfGlyphs {
			var lineRange = NSRange()
			layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
			glyphIndex = NSMaxRange(lineRange)
			lineCount += 1
		}
		return lineCount
	}
}

private struct EntryLocationMap: View {
	@Environment(\.openURL) private var openURL
	let location: JournalLocation

	private var coordinate: CLLocationCoordinate2D {
		CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
	}

	private var googleMapsURL: URL? {
		var components = URLComponents(string: "https://www.google.com/maps/search/")
		components?.queryItems = [
			URLQueryItem(name: "api", value: "1"),
			URLQueryItem(name: "query", value: "\(location.latitude),\(location.longitude)")
		]
		return components?.url
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 13) {
			Label(location.displayName, systemImage: "mappin.circle.fill")
				.font(.system(size: 17, weight: .semibold))
				.foregroundStyle(AppStyle.accent)

			Button {
				if let googleMapsURL {
					openURL(googleMapsURL)
				}
			} label: {
				Map(
					initialPosition: .region(MKCoordinateRegion(
						center: coordinate,
						latitudinalMeters: 2_400,
						longitudinalMeters: 2_400
					)),
					interactionModes: []
				) {
					Marker(location.displayName, coordinate: coordinate)
						.tint(AppStyle.accent)
				}
				.mapStyle(.standard(elevation: .flat))
				.frame(height: 220)
				.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
				.overlay {
					RoundedRectangle(cornerRadius: 18, style: .continuous)
						.stroke(AppStyle.cardBorder, lineWidth: 0.8)
				}
				.allowsHitTesting(false)
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Open \(location.displayName) in Google Maps")
		}
	}
}

private struct EntryProcessingStatusView: View {
	let phase: EntryProcessingPhase

	var body: some View {
		HStack(spacing: 11) {
			Group {
				if phase == .complete {
					Image(systemName: "checkmark")
						.font(.system(size: 13, weight: .bold))
				} else {
					ProgressView()
						.controlSize(.small)
				}
			}
			.foregroundStyle(AppStyle.accent)
			.tint(AppStyle.accent)
			.frame(width: 30, height: 30)
			.background(AppStyle.accent.opacity(0.18), in: Circle())

			Text(phase.title)
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(.white)

			Spacer()
		}
		.padding(.horizontal, 15)
		.padding(.vertical, 12)
		.background(AppStyle.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 14, style: .continuous)
				.stroke(AppStyle.accent.opacity(0.55), lineWidth: 0.8)
		}
	}
}
