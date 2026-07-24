import SwiftUI
import UIKit

struct SettingsView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@Bindable var store: JournalStore
	@State private var draft: JournalSettings
	@State private var showsClearConfirmation = false
	@State private var showsCalendarAccessAlert = false
	@State private var isRequestingCalendarAccess = false

	init(store: JournalStore) {
		self.store = store
		_draft = State(initialValue: store.settings)
	}

	var body: some View {
		NavigationStack {
			List {
				Section("Recording") {
					Toggle("Keep screen awake", isOn: $draft.keepScreenAwakeWhileRecording)
					Toggle("Haptics", isOn: $draft.hapticsEnabled)
				}
				.listRowBackground(AppStyle.background)

				Section("Journal") {
					Toggle("Show transcripts", isOn: $draft.showTranscripts)
				}
				.listRowBackground(AppStyle.background)

				Section {
					Toggle(
						"Prefer ElevenLabs transcription",
						isOn: $draft.preferElevenLabsTranscription
					)
				} header: {
					Text("Transcription")
				} footer: {
					Text("Apple Speech is used automatically when ElevenLabs cannot be reached.")
				}
				.listRowBackground(AppStyle.background)

				calendarSection

				if draft.calendarSyncEnabled {
					reminderSection
				}

				Section("Model") {
					NavigationLink {
						ReminderBenchmarkView()
					} label: {
						Label("Reminder benchmark", systemImage: "gauge.with.dots.needle.67percent")
					}
				}
				.listRowBackground(AppStyle.background)

				Section("Data") {
					Button("Delete all entries", role: .destructive) {
						showsClearConfirmation = true
					}
					.disabled(store.entries.isEmpty || store.isDemoMode)
				}
				.listRowBackground(AppStyle.background)
			}
			.listStyle(.plain)
			.scrollContentBackground(.hidden)
			.background(AppStyle.background)
			.navigationTitle("Settings")
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
		}
		.preferredColorScheme(.dark)
		.presentationBackground(AppStyle.background)
		.onChange(of: draft) { _, newValue in store.updateSettings(newValue) }
		.alert("Delete the journal?", isPresented: $showsClearConfirmation) {
			Button("Cancel", role: .cancel) {}
			Button("Delete all", role: .destructive) { store.clearJournal() }
		} message: {
			Text("This permanently deletes every note, recording, and iCloud Drive export.")
		}
		.alert("Calendar access is off", isPresented: $showsCalendarAccessAlert) {
			Button("Not now", role: .cancel) {}
			Button("Open Settings") {
				if let url = URL(string: UIApplication.openSettingsURLString) {
					openURL(url)
				}
			}
		} message: {
			Text("Allow Calendar access in Settings to attach events to recordings.")
		}
	}

	private var calendarSection: some View {
		Section {
			Toggle("Calendar sync", isOn: calendarSyncBinding)
				.disabled(isRequestingCalendarAccess)

			if draft.calendarSyncEnabled {
				Picker("Preferred calendar", selection: $draft.preferredCalendarApp) {
					ForEach(PreferredCalendarApp.allCases) { app in
						Text(app.title).tag(app)
					}
				}

				ForEach(store.calendarSync.calendars) { calendar in
					CalendarSettingRow(
						calendar: calendar,
						isIncluded: calendarBinding(for: calendar)
					)
				}
			}
		} header: {
			Text("Calendar")
		} footer: {
			Text("MyVoiceMemo only reads events. iOS requires full Calendar access to make events available.")
		}
		.listRowBackground(AppStyle.background)
	}

	private var reminderSection: some View {
		Section {
			Toggle("Event reminders", isOn: $draft.eventRemindersEnabled)

			if draft.eventRemindersEnabled {
				Toggle("Live Activities", isOn: $draft.eventReminderLiveActivitiesEnabled)
				Picker("Start before event", selection: $draft.eventReminderLeadMinutes) {
					Text("15 minutes").tag(15)
					Text("30 minutes").tag(30)
					Text("1 hour").tag(60)
					Text("90 minutes").tag(90)
					Text("2 hours").tag(120)
				}
			}
		} header: {
			Text("Event reminders")
		} footer: {
			Text("Useful cues from an event memo can return before matching calendar events. Live Activities end when the event ends.")
		}
		.listRowBackground(AppStyle.background)
	}

	private var calendarSyncBinding: Binding<Bool> {
		Binding(
			get: { draft.calendarSyncEnabled },
			set: { enabled in
				if !enabled {
					draft.calendarSyncEnabled = false
					return
				}
				isRequestingCalendarAccess = true
				Task {
					let granted = await store.requestCalendarAccess()
					draft.calendarSyncEnabled = granted
					isRequestingCalendarAccess = false
					if !granted {
						showsCalendarAccessAlert = true
					}
				}
			}
		)
	}

	private func calendarBinding(for calendar: CalendarSource) -> Binding<Bool> {
		Binding(
			get: {
				draft.includedCalendarIdentifiers?.contains(calendar.id) ?? true
			},
			set: { isIncluded in
				var identifiers = draft.includedCalendarIdentifiers
					?? Set(store.calendarSync.calendars.map(\.id))
				if isIncluded {
					identifiers.insert(calendar.id)
				} else {
					identifiers.remove(calendar.id)
				}
				draft.includedCalendarIdentifiers = identifiers
			}
		)
	}
}

private struct CalendarSettingRow: View {
	let calendar: CalendarSource
	@Binding var isIncluded: Bool

	var body: some View {
		Toggle(isOn: $isIncluded) {
			VStack(alignment: .leading, spacing: 2) {
				Text(calendar.title)
				Text(calendar.sourceTitle)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}
}
