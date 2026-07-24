import EventKit
import EventKitUI
import MapKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EntryView: View {
	@Environment(\.dismiss) private var dismiss
	@Bindable var store: JournalStore
	let entry: JournalEntry
	@State private var playback = AudioPlayback()
	@State private var presentedCalendarEvent: PresentedCalendarEvent?
	@State private var isMissingCalendarEventAlertPresented = false
	@State private var showsReminderFeedback = false
	@State private var showsNoteActions = false
	@State private var sharedEntry: JournalEntry?
	@Namespace private var noteActionsNamespace

	private var currentEntry: JournalEntry {
		store.entry(id: entry.id) ?? entry
	}

	var body: some View {
		ZStack {
			AppStyle.background.ignoresSafeArea()

			List {
				VStack(alignment: .leading, spacing: 6) {
					HStack(alignment: .firstTextBaseline, spacing: 16) {
						Text(currentEntry.location?.displayName ?? "Voice memo")
							.font(.system(size: 25, weight: .semibold))
							.foregroundStyle(.white)
							.lineLimit(1)
							.truncationMode(.tail)
						Spacer(minLength: 0)
						Text(currentEntry.createdAt.compactHeaderText)
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
				.entryListRow()

				if let phase = store.processingPhase(for: entry.id) {
					EntryProcessingStatusView(phase: phase)
						.transition(.move(edge: .top).combined(with: .opacity))
						.entryListRow()
				}

				VStack(alignment: .leading, spacing: 16) {
					Text(currentEntry.headline)
						.font(.system(size: 22, weight: .semibold))
						.foregroundStyle(.white)
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
						.frame(maxWidth: .infinity, alignment: .center)

					if store.settings.showModelNames,
						currentEntry.summary?.isEmpty != false,
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
				.entryListRow()

				if let summary = currentEntry.summary, !summary.isEmpty {
					VStack(alignment: .leading, spacing: 10) {
						Text(summary)
							.font(.system(size: 18, weight: .medium))
							.foregroundStyle(Color.white.opacity(0.94))
							.lineSpacing(5)
							.fixedSize(horizontal: false, vertical: true)

						if store.settings.showModelNames,
							let model = currentEntry.summaryModel {
							ModelAttribution(model: model)
						}
					}
						.entryListRow()
				}

				if currentEntry.calendarEvent != nil {
					if currentEntry.reminders.isEmpty {
						reminderFeedbackButton(empty: true)
							.entryListRow()
					} else {
						ForEach(currentEntry.reminders) { reminder in
							ReminderRuleRow(reminder: reminder)
								.listRowInsets(EdgeInsets(
									top: 0,
									leading: 24,
									bottom: 0,
									trailing: 24
								))
								.listRowBackground(AppStyle.background)
								.listRowSeparator(
									reminder.id == currentEntry.reminders.last?.id
										? .hidden
										: .visible
								)
								.listRowSeparatorTint(Color.white.opacity(0.14))
								.swipeActions(edge: .trailing, allowsFullSwipe: true) {
									Button(role: .destructive) {
										withAnimation(.easeOut(duration: 0.2)) {
											store.removeReminder(
												entryID: entry.id,
												reminderID: reminder.id
											)
										}
									} label: {
										Label("Remove", systemImage: "trash")
									}
								}
						}

						VStack(alignment: .leading, spacing: 14) {
							reminderFeedbackButton(empty: false)
							if store.settings.showModelNames,
								let model = currentEntry.reminderModel {
								ModelAttribution(model: model)
							}
						}
						.entryListRow()
					}
				}

				if store.settings.showTranscripts, !currentEntry.transcript.isEmpty {
					VStack(alignment: .leading, spacing: 12) {
						SummaryToPopup(
							text: currentEntry.transcript,
							accessibilityName: "Transcript"
						)
							.contentTransition(.opacity)

						if store.settings.showModelNames,
							let model = currentEntry.transcriptModel {
							ModelAttribution(model: model)
						}
					}
						.entryListRow()
				}

				if let location = currentEntry.location {
					EntryLocationMap(location: location)
						.transition(.move(edge: .bottom).combined(with: .opacity))
						.entryListRow()
				}

				Color.clear
					.frame(height: 64)
					.listRowInsets(EdgeInsets())
					.listRowBackground(AppStyle.background)
					.listRowSeparator(.hidden)
			}
			.listStyle(.plain)
			.scrollContentBackground(.hidden)
			.scrollIndicators(.hidden)
			.environment(\.defaultMinListRowHeight, 0)
		}
		.overlay {
			ZStack(alignment: .bottomLeading) {
				if showsNoteActions {
					Color.clear
						.contentShape(Rectangle())
						.onTapGesture { setNoteActionsPresented(false) }
						.accessibilityHidden(true)
				}

				noteActionsMenu
					.padding(.leading, 20)
					.padding(.bottom, 10)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		}
		.presentationBackground(AppStyle.background)
		.toolbar(.hidden, for: .navigationBar)
		.background(NativeBackSwipeEnabler())
		.animation(.easeOut(duration: 0.22), value: store.processingPhase(for: entry.id))
		.animation(.easeOut(duration: 0.28), value: currentEntry.location)
		.task {
			if ProcessInfo.processInfo.arguments.contains("-demo-reminder-feedback") {
				showsReminderFeedback = true
			}
		}
		.onDisappear { playback.stop() }
		.sheet(item: $presentedCalendarEvent) { presentedEvent in
			CalendarEventDetail(event: presentedEvent.event)
		}
		.sheet(isPresented: $showsReminderFeedback) {
			ReminderFeedbackView(store: store, entryID: entry.id)
		}
		.sheet(item: $sharedEntry) { entry in
			JournalEntryShareSheet(entry: entry)
		}
		.alert("Event unavailable", isPresented: $isMissingCalendarEventAlertPresented) {
			Button("OK", role: .cancel) {}
		} message: {
			Text("This event is no longer available in the calendars on this iPhone.")
		}
		.accessibilityAction(.escape) { dismiss() }
	}

	private var noteActionsMenu: some View {
		GlassEffectContainer(spacing: 16) {
			if showsNoteActions {
				noteActionsPanel
					.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
					.glassEffectID("note-actions", in: noteActionsNamespace)
					.glassEffectTransition(.matchedGeometry)
			} else {
				Button {
					setNoteActionsPresented(true)
				} label: {
					Image(systemName: "ellipsis")
						.font(.system(size: 18, weight: .bold))
						.foregroundStyle(.white)
						.frame(width: 50, height: 50)
						.contentShape(Circle())
				}
				.buttonStyle(.plain)
				.glassEffect(.regular.interactive(), in: Circle())
				.glassEffectID("note-actions", in: noteActionsNamespace)
				.glassEffectTransition(.matchedGeometry)
				.accessibilityLabel("Note actions")
			}
		}
	}

	private var noteActionsPanel: some View {
		VStack(spacing: 0) {
			Toggle(isOn: showModelNamesBinding) {
				Label("Show Models", systemImage: "apple.intelligence")
					.lineLimit(1)
			}
			.toggleStyle(.switch)
			.controlSize(.small)
			.padding(.horizontal, 16)
			.frame(height: 52)

			Divider()

			Button {
				setNoteActionsPresented(false)
				store.reprocessEntry(id: entry.id)
			} label: {
				Label("Reprocess", systemImage: "dice.fill")
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 16)
			.frame(height: 52)
			.disabled(
				currentEntry.transcript.isEmpty
					|| store.processingPhase(for: entry.id) != nil
			)

			Divider()

			Button {
				let entryToShare = currentEntry
				setNoteActionsPresented(false)
				Task { @MainActor in
					try? await Task.sleep(for: .milliseconds(250))
					sharedEntry = entryToShare
				}
			} label: {
				Label("Share", systemImage: "square.and.arrow.up")
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 16)
			.frame(height: 52)
		}
		.frame(width: 260)
	}

	private func setNoteActionsPresented(_ isPresented: Bool) {
		withAnimation(.spring(duration: 0.34, bounce: 0.18)) {
			showsNoteActions = isPresented
		}
	}

	private var showModelNamesBinding: Binding<Bool> {
		Binding(
			get: { store.settings.showModelNames },
			set: { store.setShowModelNames($0) }
		)
	}

	private func reminderFeedbackButton(empty: Bool) -> some View {
		Button {
			showsReminderFeedback = true
		} label: {
			Label(
				empty ? "No reminders: Add feedback" : "Add feedback",
				systemImage: "waveform"
			)
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(AppStyle.accent)
		}
		.buttonStyle(.plain)
		.disabled(
			!store.settings.eventRemindersEnabled
				|| store.processingPhase(for: entry.id) != nil
		)
		.accessibilityHint("Records a temporary correction and reprocesses these reminders")
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

private struct JournalEntryShareSheet: UIViewControllerRepresentable {
	let entry: JournalEntry

	func makeUIViewController(context: Context) -> UIActivityViewController {
		let item = try? JournalEntryActivityItem(entry: entry)
		return UIActivityViewController(
			activityItems: item.map { [$0] } ?? [entry.headline],
			applicationActivities: nil
		)
	}

	func updateUIViewController(
		_ uiViewController: UIActivityViewController,
		context: Context
	) {}
}

private final class JournalEntryActivityItem: NSObject, UIActivityItemSource {
	private let fileURL: URL
	private let jsonText: String
	private let subject: String

	init(entry: JournalEntry) throws {
		let data = try entry.jsonData()
		fileURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("MyVoiceMemo_\(entry.id.uuidString).json")
		jsonText = String(decoding: data, as: UTF8.self)
		subject = entry.headline
		try data.write(to: fileURL, options: .atomic)
	}

	func activityViewControllerPlaceholderItem(
		_ activityViewController: UIActivityViewController
	) -> Any {
		fileURL
	}

	func activityViewController(
		_ activityViewController: UIActivityViewController,
		itemForActivityType activityType: UIActivity.ActivityType?
	) -> Any? {
		activityType == .copyToPasteboard ? jsonText : fileURL
	}

	func activityViewController(
		_ activityViewController: UIActivityViewController,
		subjectForActivityType activityType: UIActivity.ActivityType?
	) -> String {
		subject
	}

	func activityViewController(
		_ activityViewController: UIActivityViewController,
		dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
	) -> String {
		activityType == .copyToPasteboard
			? UTType.utf8PlainText.identifier
			: UTType.json.identifier
	}
}

private extension View {
	func entryListRow(bottom: CGFloat = 32) -> some View {
		listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: bottom, trailing: 24))
			.listRowBackground(AppStyle.background)
			.listRowSeparator(.hidden)
	}
}

private struct ReminderRuleRow: View {
	let reminder: EventReminderRule
	@State private var isExpanded = false

	private var scheduleText: String {
		var text = "\(reminder.occurrencePolicy.title) “\(reminder.selector.title)”"
		if let expiresAt = reminder.expiresAt {
			text += " until \(expiresAt.formatted(date: .abbreviated, time: .omitted))"
		}
		return text
	}

	private var hasDetails: Bool {
		!reminder.evidence.isEmpty
			|| !reminder.motivation.isEmpty
			|| !reminder.selector.examples.isEmpty
	}

	var body: some View {
		Group {
			if hasDetails {
				DisclosureGroup(isExpanded: $isExpanded) {
					reminderDetails
				} label: {
					reminderLabel
				}
			} else {
				reminderLabel
			}
		}
		.tint(AppStyle.secondary)
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
		.accessibilityValue(hasDetails ? (isExpanded ? "Expanded" : "Collapsed") : "")
		.accessibilityHint(hasDetails ? "Shows or hides why this reminder appears" : "")
		.padding(.vertical, 10)
	}

	private var reminderLabel: some View {
		HStack(alignment: .top, spacing: 11) {
			Image(systemName: "circle")
				.font(.system(size: 17, weight: .medium))
				.foregroundStyle(AppStyle.accent)
				.padding(.top, 2)

			VStack(alignment: .leading, spacing: 4) {
				Text(reminder.text)
					.font(.system(size: 16, weight: .semibold))
					.foregroundStyle(.white)
					.fixedSize(horizontal: false, vertical: true)
				Text(scheduleText)
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(AppStyle.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			Spacer(minLength: 4)
		}
	}

	@ViewBuilder
	private var reminderDetails: some View {
		VStack(alignment: .leading, spacing: 10) {
			if !reminder.motivation.isEmpty {
				ReminderDetail(label: "Why", text: reminder.motivation)
			}
			if !reminder.evidence.isEmpty {
				ReminderDetail(label: "From your recordings", text: "“\(reminder.evidence)”")
			}
			ForEach(reminder.selector.examples) { example in
				HStack(alignment: .top, spacing: 11) {
					Image(systemName: example.matches ? "checkmark.circle.fill" : "xmark.circle")
						.foregroundStyle(example.matches ? AppStyle.accent : AppStyle.tertiary)
					VStack(alignment: .leading, spacing: 4) {
						Text(example.event.title)
							.font(.system(size: 13, weight: .semibold))
							.foregroundStyle(.white)
						Text(example.reason)
							.font(.caption)
							.foregroundStyle(AppStyle.secondary)
					}
				}
			}
		}
	}
}

private struct ReminderDetail: View {
	let label: String
	let text: String

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(label.uppercased())
				.font(.system(size: 10, weight: .bold))
				.foregroundStyle(AppStyle.tertiary)
				.tracking(0.5)
			Text(text)
				.font(.system(size: 13))
				.foregroundStyle(AppStyle.secondary)
				.fixedSize(horizontal: false, vertical: true)
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
				.allowsHitTesting(false)

				Button {
					ExternalLinks.openGoogleMaps(location: location)
				} label: {
					Rectangle()
						.fill(.clear)
						.contentShape(Rectangle())
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
			.frame(width: 24, height: 30)

			Text(phase.title)
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(.white)

			Spacer()
		}
		.padding(.vertical, 4)
	}
}
