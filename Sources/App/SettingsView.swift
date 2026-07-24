import SwiftUI
#if os(iOS)
import UIKit
#endif

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
			Form {
				Section("Recording") {
					Toggle("Keep screen awake", isOn: $draft.keepScreenAwakeWhileRecording)
					Toggle("Haptics", isOn: $draft.hapticsEnabled)
				}

				Section("Journal") {
					Toggle("Show transcripts", isOn: $draft.showTranscripts)
				}

				calendarSection

				Section("Data") {
					Button("Delete all entries", role: .destructive) {
						showsClearConfirmation = true
					}
					.disabled(store.entries.isEmpty || store.isDemoMode)
				}
			}
			.scrollContentBackground(.hidden)
			.background(.black)
			.navigationTitle("Settings")
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
		}
		.preferredColorScheme(.dark)
		.presentationBackground(.black)
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
