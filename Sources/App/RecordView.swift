import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RecordView: View {
	@Bindable var store: JournalStore
	let startsImmediately: Bool
	let onClose: () -> Void
	let onFinished: (UUID) -> Void

	@State private var recorder = AudioRecorder()
	@State private var liveActivity = RecordingActivityManager()
	@State private var errorMessage: String?
	@State private var isFinishing = false
	@State private var activeRecordingURL: URL?
	@State private var lastCheckpointSecond = 0
	@State private var hasStartedRecording = false
	@State private var isAttachedToEvent = false
	@State private var selectedEventID: String?
	@State private var isLoadingEvents = true

	private var isVisualDemo: Bool {
		ProcessInfo.processInfo.arguments.contains("-demo-recording")
	}

	private var shownDuration: TimeInterval {
		isVisualDemo ? 113 : recorder.duration
	}

	private var events: [JournalCalendarEvent] {
		store.calendarSync.events
	}

	private var selectedCalendarEvent: JournalCalendarEvent? {
		guard isAttachedToEvent, let selectedEventID else { return nil }
		return events.first { $0.id == selectedEventID }
	}

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			if hasStartedRecording || isVisualDemo {
				recordingView
			} else {
				setupView
			}
		}
		.presentationBackground(.black)
		.task {
			if startsImmediately || isVisualDemo {
				hasStartedRecording = true
				await beginRecording()
			} else {
				await prepareEventSelection()
			}
		}
		.onDisappear {
			liveActivity.end()
			if !isFinishing {
				discardActiveRecording()
				#if os(iOS)
				UIApplication.shared.isIdleTimerDisabled = false
				#endif
			}
		}
		.onChange(of: recorder.duration) { _, duration in
			checkpointIfNeeded(duration: duration)
		}
		.onChange(of: recorder.isPaused) { _, isPaused in
			liveActivity.setPaused(isPaused, elapsed: recorder.duration)
		}
		.onChange(of: isAttachedToEvent) { _, isAttached in
			if isAttached {
				selectClosestEvent()
			} else {
				selectedEventID = nil
			}
		}
		.onChange(of: events) { _, _ in
			guard isAttachedToEvent, selectedEventID == nil else { return }
			selectClosestEvent()
		}
		.alert("Recording unavailable", isPresented: Binding(
			get: { errorMessage != nil },
			set: { if !$0 { errorMessage = nil } }
		)) {
			Button("Close") { onClose() }
		} message: {
			Text(errorMessage ?? "")
		}
	}

	private var setupView: some View {
		VStack(spacing: 0) {
			closeButton

			ScrollView {
				VStack(alignment: .leading, spacing: 24) {
					Text("New recording")
						.font(.system(size: 30, weight: .semibold))
						.foregroundStyle(.white)

					Toggle(isOn: $isAttachedToEvent) {
						Label("Attached to event", systemImage: "calendar")
							.font(.system(size: 17, weight: .semibold))
					}
					.tint(AppStyle.accent)
					.disabled(!store.settings.calendarSyncEnabled || events.isEmpty)

					eventList
						.opacity(isAttachedToEvent ? 1 : 0.36)
						.scaleEffect(isAttachedToEvent ? 1 : 0.94, anchor: .top)
						.allowsHitTesting(isAttachedToEvent)
						.animation(.easeOut(duration: 0.2), value: isAttachedToEvent)
				}
				.padding(.horizontal, 24)
				.padding(.bottom, 120)
			}
			.scrollIndicators(.hidden)

			Button(action: startRecording) {
				Label("Start recording", systemImage: "mic.fill")
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(.white)
					.frame(maxWidth: .infinity)
					.frame(height: 58)
					.background(AppStyle.accent, in: Capsule())
					.shadow(color: AppStyle.accent.opacity(0.34), radius: 18, y: 8)
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 24)
			.padding(.bottom, 28)
		}
	}

	@ViewBuilder
	private var eventList: some View {
		if isLoadingEvents {
			HStack(spacing: 10) {
				ProgressView()
				.tint(AppStyle.accent)
				Text("Loading today’s events")
					.font(.system(size: 15, weight: .medium))
					.foregroundStyle(AppStyle.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 20)
		} else if events.isEmpty {
			Text(store.settings.calendarSyncEnabled ? "No events today" : "Calendar sync is off")
				.font(.system(size: 15, weight: .medium))
				.foregroundStyle(AppStyle.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.vertical, 20)
		} else {
			LazyVStack(spacing: 10) {
				ForEach(events) { event in
					Button {
						selectedEventID = event.id
					} label: {
						EventSelectionRow(
							event: event,
							isSelected: selectedEventID == event.id
						)
					}
					.buttonStyle(.plain)
				}
			}
		}
	}

	private var recordingView: some View {
		VStack(spacing: 0) {
			closeButton

			Spacer()

			WaveformView(levels: displayLevels)
				.frame(height: 54)
				.padding(.horizontal, 52)
				.offset(y: -45)

			Text(shownDuration.clockText)
				.font(.system(size: 20, weight: .regular, design: .monospaced))
				.monospacedDigit()
				.padding(.top, 12)
				.offset(y: -40)

			if let statusMessage = recorder.statusMessage {
				Text(statusMessage)
					.font(.system(size: 14, weight: .medium))
					.foregroundStyle(AppStyle.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 54)
					.offset(y: -34)
			}

			Spacer()

			HStack(spacing: 34) {
				Button(action: togglePause) {
					Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(AppStyle.accent)
						.frame(width: 48, height: 48)
						.glassEffect(.regular.interactive(), in: Circle())
				}
				.buttonStyle(.plain)
				.disabled(!isVisualDemo && !recorder.isRecording)
				.accessibilityLabel(recorder.isPaused ? "Resume" : "Pause")

				Button(action: finish) {
					Image(systemName: "checkmark")
						.font(.system(size: 20, weight: .medium))
						.foregroundStyle(.white)
						.frame(width: 62, height: 62)
						.background(AppStyle.accent, in: Circle())
						.shadow(color: AppStyle.accent.opacity(0.38), radius: 18, y: 7)
				}
				.buttonStyle(.plain)
				.disabled(!isVisualDemo && (!recorder.isRecording || isFinishing))
				.accessibilityLabel("Finish recording")
			}
			.padding(.bottom, 63)
			.offset(x: -52)
		}
	}

	private var closeButton: some View {
		HStack {
			Spacer()
			Button(action: cancel) {
				Image(systemName: "trash.fill")
					.font(.system(size: 15, weight: .semibold))
					.foregroundStyle(.red)
					.frame(width: 44, height: 44)
					.glassEffect(.regular.tint(.red.opacity(0.12)).interactive(), in: Circle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Discard recording")
			.padding(.top, 18)
		}
		.padding(.trailing, 8)
	}

	private var displayLevels: [Double] {
		if isVisualDemo {
			return [
				0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
				0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
				0.40, 0.72, 0.92, 0.86, 0.78, 0.70, 0.82, 0.74, 0.65, 0.78,
				0.60, 0.53, 0.45, 0.38, 0.30, 0.22, 0.16, 0.12, 0.08,
				0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
				0.25, 0.34, 0.42, 0.38, 0.31, 0.36, 0.44, 0.39, 0.34, 0.31, 0.28, 0.24, 0.21
			]
		}
		if recorder.levels.allSatisfy({ $0 <= 0.08 }) {
			return recorder.levels.enumerated().map { index, _ in
				let center = Double(recorder.levels.count) / 2
				let distance = abs(Double(index) - center) / center
				return max(0.06, (1 - distance) * 0.42 + Double(index % 5) * 0.055)
			}
		}
		return recorder.levels
	}

	private func prepareEventSelection() async {
		await store.refreshCalendar()
		isLoadingEvents = false
		isAttachedToEvent = store.settings.calendarSyncEnabled && !events.isEmpty
		if isAttachedToEvent {
			selectClosestEvent()
		}
	}

	private func selectClosestEvent() {
		let now = Date.now
		let currentTimedEvents = events.filter {
			!$0.isAllDay && $0.startDate <= now && now <= $0.endDate
		}
		if let currentEvent = currentTimedEvents.max(by: { $0.startDate < $1.startDate }) {
			selectedEventID = currentEvent.id
			return
		}

		let timedEvents = events.filter { !$0.isAllDay }
		let candidates = timedEvents.isEmpty ? events : timedEvents
		selectedEventID = candidates.min { lhs, rhs in
			eventDistance(lhs, from: now) < eventDistance(rhs, from: now)
		}?.id
	}

	private func eventDistance(_ event: JournalCalendarEvent, from date: Date) -> TimeInterval {
		if date >= event.startDate, date <= event.endDate {
			return 0
		}
		if date < event.startDate {
			return event.startDate.timeIntervalSince(date)
		}
		return date.timeIntervalSince(event.endDate)
	}

	private func startRecording() {
		hasStartedRecording = true
		Task { await beginRecording() }
	}

	private func beginRecording() async {
		guard !isVisualDemo else {
			liveActivity.start(elapsed: shownDuration, locationName: "Chicago")
			return
		}
		var destination: URL?
		do {
			let url = try store.destinationForNewRecording(calendarEvent: selectedCalendarEvent)
			destination = url
			activeRecordingURL = url
			try await recorder.start(at: url)
			guard !Task.isCancelled else {
				discardActiveRecording()
				return
			}
			liveActivity.start()
			impact(.light)
			let locationTask = store.beginRecordingLocationCapture()
			Task { @MainActor in
				let location = await locationTask.value
				guard activeRecordingURL == url else { return }
				liveActivity.setLocation(location?.displayName)
			}
			#if os(iOS)
			if store.settings.keepScreenAwakeWhileRecording {
				UIApplication.shared.isIdleTimerDisabled = true
			}
			#endif
		} catch {
			discardActiveRecording(fallbackURL: destination)
			guard !Task.isCancelled else { return }
			errorMessage = error.localizedDescription
		}
	}

	private func finish() {
		guard !isVisualDemo else { return }
		guard !isFinishing, let recording = recorder.finish() else { return }
		activeRecordingURL = nil
		liveActivity.end()
		isFinishing = true
		#if os(iOS)
		UIApplication.shared.isIdleTimerDisabled = false
		#endif
		impact(.medium)
		let entryID = store.finishRecording(
			at: recording.url,
			duration: recording.duration,
			calendarEvent: selectedCalendarEvent
		)
		onFinished(entryID)
	}

	private func cancel() {
		discardActiveRecording()
		liveActivity.end()
		#if os(iOS)
		UIApplication.shared.isIdleTimerDisabled = false
		#endif
		notification(.warning)
		onClose()
	}

	private func discardActiveRecording(fallbackURL: URL? = nil) {
		let url = recorder.cancel() ?? activeRecordingURL ?? fallbackURL
		activeRecordingURL = nil
		guard let url else { return }
		try? FileManager.default.removeItem(at: url)
		store.cancelRecording(at: url)
	}

	private func togglePause() {
		recorder.togglePause()
		impact(.soft)
	}

	private func checkpointIfNeeded(duration: TimeInterval) {
		guard let activeRecordingURL else { return }
		let second = Int(duration)
		guard second >= lastCheckpointSecond + 5 else { return }
		lastCheckpointSecond = second
		store.checkpointRecording(at: activeRecordingURL, duration: duration)
	}

	#if os(iOS)
	private func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
		guard store.settings.hapticsEnabled else { return }
		UIImpactFeedbackGenerator(style: style).impactOccurred()
	}

	private func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
		guard store.settings.hapticsEnabled else { return }
		UINotificationFeedbackGenerator().notificationOccurred(type)
	}
	#endif
}

private struct EventSelectionRow: View {
	let event: JournalCalendarEvent
	let isSelected: Bool

	private var timeText: String {
		if event.isAllDay {
			return "All day"
		}
		let start = event.startDate.formatted(date: .omitted, time: .shortened)
		let end = event.endDate.formatted(date: .omitted, time: .shortened)
		return "\(start)–\(end)"
	}

	var body: some View {
		HStack(spacing: 13) {
			VStack(alignment: .leading, spacing: 5) {
				Text(event.title)
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(.white)
					.multilineTextAlignment(.leading)
					.lineLimit(2)

				Text("\(timeText) · \(event.calendarTitle)")
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(AppStyle.secondary)
					.lineLimit(1)
			}

			Spacer(minLength: 8)

			Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
				.font(.system(size: 21, weight: .semibold))
				.foregroundStyle(isSelected ? AppStyle.accent : AppStyle.tertiary)
		}
		.padding(16)
		.background(
			isSelected ? AppStyle.accentSoft : AppStyle.card,
			in: RoundedRectangle(cornerRadius: 15, style: .continuous)
		)
		.overlay {
			RoundedRectangle(cornerRadius: 15, style: .continuous)
				.stroke(
					isSelected ? AppStyle.accent.opacity(0.72) : AppStyle.cardBorder,
					lineWidth: 0.8
				)
		}
	}
}
