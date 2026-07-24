import EventKit
import EventKitUI
import MapKit
import SwiftUI
import UIKit

struct EntryView: View {
	@Bindable var store: JournalStore
	let entry: JournalEntry
	let onBack: () -> Void
	@State private var playback = AudioPlayback()
	@State private var presentedCalendarEvent: PresentedCalendarEvent?
	@State private var isMissingCalendarEventAlertPresented = false

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
					VStack(alignment: .leading, spacing: 6) {
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

						if let calendarEvent = currentEntry.calendarEvent {
							Button {
								openCalendarEvent(calendarEvent)
							} label: {
								HStack(spacing: 10) {
									Image(systemName: "calendar")
										.foregroundStyle(AppStyle.accent)
									Text(calendarEvent.title)
										.font(.system(size: 16, weight: .semibold))
										.foregroundStyle(.white)
										.lineLimit(1)
									Spacer(minLength: 0)
								}
								.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
								.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
							.accessibilityHint("Opens the event details")
						}
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
							.multilineTextAlignment(.center)
							.fixedSize(horizontal: false, vertical: true)
							.frame(maxWidth: .infinity, alignment: .center)

						if currentEntry.summary?.isEmpty != false,
							let model = currentEntry.summaryModel {
							ModelAttribution(model: model)
						}

						if let audioURL = store.audioURL(for: currentEntry) {
							EntryAudioPlayer(playback: playback, duration: currentEntry.duration)
								.task(id: audioURL) {
									await playback.load(url: audioURL, fallbackDuration: currentEntry.duration)
								}
						}
					}

					if let summary = currentEntry.summary, !summary.isEmpty {
						VStack(alignment: .leading, spacing: 10) {
							Text(summary)
								.font(.system(size: 18, weight: .medium))
								.foregroundStyle(Color.white.opacity(0.94))
								.lineSpacing(5)
								.fixedSize(horizontal: false, vertical: true)

							if let model = currentEntry.summaryModel {
								ModelAttribution(model: model)
							}
						}
					}

					if store.settings.showTranscripts, !currentEntry.transcript.isEmpty {
						VStack(alignment: .leading, spacing: 12) {
							SummaryToPopup(
								text: currentEntry.transcript,
								accessibilityName: "Transcript"
							)
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
		.toolbar(.hidden, for: .navigationBar)
		.simultaneousGesture(
			DragGesture(minimumDistance: 16)
				.onEnded { value in
					guard value.startLocation.x <= 32,
						value.translation.width >= 64,
						value.translation.width > abs(value.translation.height)
					else { return }
					onBack()
				}
		)
		.animation(.easeOut(duration: 0.22), value: store.processingPhase(for: entry.id))
		.animation(.easeOut(duration: 0.28), value: currentEntry.location)
		.onDisappear { playback.stop() }
		.sheet(item: $presentedCalendarEvent) { presentedEvent in
			CalendarEventDetail(event: presentedEvent.event)
		}
		.alert("Event unavailable", isPresented: $isMissingCalendarEventAlertPresented) {
			Button("OK", role: .cancel) {}
		} message: {
			Text("This event is no longer available in the calendars on this iPhone.")
		}
		.accessibilityAction(.escape, onBack)
	}

	private func openCalendarEvent(_ event: JournalCalendarEvent) {
		let resolvedEvent = store.calendarSync.resolve(event)
		if store.settings.preferredCalendarApp == .google,
			let providerURL = event.providerURL
				?? resolvedEvent.flatMap(store.calendarSync.providerURL(for:)) {
			UIApplication.shared.open(providerURL)
			return
		}
		if let resolvedEvent {
			presentedCalendarEvent = PresentedCalendarEvent(event: resolvedEvent)
		} else {
			isMissingCalendarEventAlertPresented = true
		}
	}
}

private struct EntryAudioPlayer: View {
	@Bindable var playback: AudioPlayback
	let duration: TimeInterval

	private var shownDuration: TimeInterval {
		playback.duration > 0 ? playback.duration : duration
	}

	private var progress: Double {
		guard shownDuration > 0 else { return 0 }
		return playback.currentTime / shownDuration
	}

	var body: some View {
		HStack(spacing: 12) {
			Button(action: playback.togglePlayback) {
				Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(.white)
					.frame(width: 40, height: 40)
					.background(AppStyle.accent, in: Circle())
			}
			.buttonStyle(.plain)
			.disabled(!playback.isReady)
			.accessibilityLabel(playback.isPlaying ? "Pause recording" : "Play recording")

			ScrubbableWaveform(
				levels: playback.levels,
				progress: progress,
				onSeek: playback.seek
			)
			.frame(height: 38)

			Text(max(0, shownDuration - playback.currentTime).clockText)
				.font(.system(size: 13, weight: .medium, design: .monospaced))
				.monospacedDigit()
				.foregroundStyle(AppStyle.secondary)
				.frame(width: 42, alignment: .trailing)
				.accessibilityLabel("Remaining time")
		}
		.padding(.vertical, 2)
	}
}

private struct ScrubbableWaveform: View {
	let levels: [Double]
	let progress: Double
	let onSeek: (Double) -> Void

	var body: some View {
		GeometryReader { geometry in
			ZStack(alignment: .leading) {
				bars(color: AppStyle.accent.opacity(0.34), width: geometry.size.width)
				bars(color: AppStyle.accent, width: geometry.size.width)
					.mask(alignment: .leading) {
						Rectangle()
							.frame(width: geometry.size.width * max(0, min(1, progress)))
					}
			}
			.contentShape(Rectangle())
			.gesture(
				DragGesture(minimumDistance: 0)
					.onChanged { value in
						guard geometry.size.width > 0 else { return }
						onSeek(value.location.x / geometry.size.width)
					}
			)
		}
		.accessibilityElement()
		.accessibilityLabel("Playback position")
		.accessibilityValue("\(Int(progress * 100)) percent")
		.accessibilityAdjustableAction { direction in
			switch direction {
			case .increment: onSeek(min(1, progress + 0.05))
			case .decrement: onSeek(max(0, progress - 0.05))
			@unknown default: break
			}
		}
	}

	private func bars(color: Color, width: CGFloat) -> some View {
		HStack(spacing: 2) {
			ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
				Capsule()
					.fill(color)
					.frame(
						width: max(1, (width - CGFloat(levels.count - 1) * 2) / CGFloat(levels.count)),
						height: max(3, 34 * level)
					)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

private struct PresentedCalendarEvent: Identifiable {
	let id = UUID()
	let event: EKEvent
}

private struct CalendarEventDetail: UIViewControllerRepresentable {
	let event: EKEvent
	@Environment(\.dismiss) private var dismiss

	func makeCoordinator() -> Coordinator {
		Coordinator { dismiss() }
	}

	func makeUIViewController(context: Context) -> UINavigationController {
		let controller = EKEventViewController()
		controller.event = event
		controller.allowsEditing = false
		controller.allowsCalendarPreview = true
		controller.delegate = context.coordinator
		return UINavigationController(rootViewController: controller)
	}

	func updateUIViewController(_ controller: UINavigationController, context: Context) {}

	final class Coordinator: NSObject, EKEventViewDelegate {
		let onDone: () -> Void

		init(onDone: @escaping () -> Void) {
			self.onDone = onDone
		}

		func eventViewController(_ controller: EKEventViewController, didCompleteWith action: EKEventViewAction) {
			onDone()
		}
	}
}

private struct EntryLocationMap: View {
	let location: JournalLocation

	private var coordinate: CLLocationCoordinate2D {
		CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 13) {
			Label(location.displayName, systemImage: "mappin.circle.fill")
				.font(.system(size: 17, weight: .semibold))
				.foregroundStyle(AppStyle.accent)

			ZStack {
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

				Button {
					ExternalLinks.openGoogleMaps(location: location)
				} label: {
					RoundedRectangle(cornerRadius: 18, style: .continuous)
						.fill(.clear)
						.contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Open \(location.displayName) in Google Maps")
			}
		}
	}
}

@MainActor
private enum ExternalLinks {
	static func openGoogleMaps(location: JournalLocation) {
		let coordinate = "\(location.latitude),\(location.longitude)"
		var components = URLComponents(string: "https://www.google.com/maps/search/")
		components?.queryItems = [
			URLQueryItem(name: "api", value: "1"),
			URLQueryItem(name: "query", value: coordinate)
		]
		guard let webURL = components?.url else { return }

		if let appURL = URL(string: "comgooglemaps://?q=\(coordinate)"),
			UIApplication.shared.canOpenURL(appURL) {
			UIApplication.shared.open(appURL) { didOpen in
				guard !didOpen else { return }
				Task { @MainActor in UIApplication.shared.open(webURL) }
			}
			return
		}

		UIApplication.shared.open(webURL)
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
