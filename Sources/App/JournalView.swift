import SwiftUI

struct JournalView: View {
	@Bindable var store: JournalStore
	let onSelectEntry: (JournalEntry) -> Void
	let onNewRecording: () -> Void
	let onReview: () -> Void
	let onSettings: () -> Void

	@State private var entryPendingDeletion: JournalEntry?

	private var visibleEntries: [JournalEntry] {
		store.entries.sorted { $0.createdAt > $1.createdAt }
	}

	var body: some View {
		ZStack(alignment: .bottom) {
			Color.black.ignoresSafeArea()

			List {
				header
					.padding(.horizontal, 20)
					.padding(.bottom, 20)
				.listRowInsets(EdgeInsets())
				.listRowBackground(Color.black)
				.listRowSeparator(.hidden)

				if visibleEntries.isEmpty {
					emptyState
						.listRowInsets(EdgeInsets())
						.listRowBackground(Color.black)
						.listRowSeparator(.hidden)
				} else {
					ForEach(visibleEntries) { entry in
						Button { onSelectEntry(entry) } label: {
							EntryCard(entry: entry, processingPhase: store.processingPhase(for: entry.id))
						}
						.buttonStyle(.plain)
						.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 9, trailing: 20))
						.listRowBackground(Color.black)
						.listRowSeparator(.hidden)
						.swipeActions(edge: .trailing, allowsFullSwipe: false) {
							Button {
								entryPendingDeletion = entry
							} label: {
								Label("Delete", systemImage: "trash.fill")
							}
							.tint(.red)
						}
					}
				}

				Color.clear
					.frame(height: 95)
					.listRowInsets(EdgeInsets())
					.listRowBackground(Color.black)
					.listRowSeparator(.hidden)
			}
			.listStyle(.plain)
			.scrollContentBackground(.hidden)
			.scrollIndicators(.hidden)
			.environment(\.defaultMinListRowHeight, 0)

			HStack {
				Button(action: onReview) {
					Label("Review", systemImage: "calendar")
						.font(.system(size: 14, weight: .medium))
						.foregroundStyle(.white)
						.padding(.horizontal, 22)
						.frame(height: 50)
						.glassEffect(.regular.interactive(), in: Capsule())
				}
				.buttonStyle(.plain)
				.accessibilityHint("Opens this week's review")

				Spacer()

				Button(action: onNewRecording) {
					Label("Record", systemImage: "mic.fill")
						.font(.system(size: 14, weight: .medium))
						.foregroundStyle(.white)
						.padding(.horizontal, 25)
						.frame(height: 50)
						.background(AppStyle.accent, in: Capsule())
						.shadow(color: AppStyle.accent.opacity(0.34), radius: 18, y: 8)
				}
				.buttonStyle(.plain)
				.accessibilityHint("Starts a voice memo")
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 18)
		}
		.alert(
			"Delete voice memo?",
			isPresented: Binding(
				get: { entryPendingDeletion != nil },
				set: { if !$0 { entryPendingDeletion = nil } }
			),
			presenting: entryPendingDeletion
		) { entry in
			Button("Delete", role: .destructive) {
				store.deleteEntry(id: entry.id)
			}
			Button("Cancel", role: .cancel) {}
		} message: { _ in
			Text("This permanently deletes the note and its recording.")
		}
	}

	private var header: some View {
		HStack {
			TimelineView(.periodic(from: .now, by: 60)) { context in
				Text(context.date.formatted(Date.FormatStyle.journalHeader))
					.font(.system(size: 32, weight: .regular))
					.foregroundStyle(.white)
			}

			Spacer()

			Button(action: onSettings) {
				Image(systemName: "gearshape")
					.font(.system(size: 17, weight: .regular))
					.foregroundStyle(Color.white.opacity(0.88))
					.frame(width: 44, height: 44)
					.glassEffect(.regular.interactive(), in: Circle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Settings")
		}
		.padding(.top, 8)
	}

	private var emptyState: some View {
		VStack(spacing: 12) {
			Text("No voice memos")
				.font(.system(size: 21, weight: .medium))
			Text("Tap Record to record.")
				.font(.system(size: 15))
				.foregroundStyle(AppStyle.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 270)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 112)
	}
}

private struct EntryCard: View {
	let entry: JournalEntry
	let processingPhase: EntryProcessingPhase?

	private var timestamp: String {
		let currentYear = Calendar.current.component(.year, from: .now)
		let entryYear = Calendar.current.component(.year, from: entry.createdAt)
		var style = Date.FormatStyle()
			.month(.abbreviated)
			.day()
			.hour(.defaultDigits(amPM: .abbreviated))
			.minute(.twoDigits)
		if entryYear != currentYear {
			style = style.year()
		}
		return entry.createdAt.formatted(style)
	}

	var body: some View {
		AppCard {
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					Text(timestamp)
					Spacer()
					Text(entry.duration.compactDurationText)
				}
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(AppStyle.tertiary)

				Text(entry.headline)
					.font(.system(size: 18, weight: .medium))
					.foregroundStyle(.white)
					.multilineTextAlignment(.leading)
					.lineLimit(3)

				if let processingPhase {
					HStack(spacing: 6) {
						if processingPhase == .complete {
							Image(systemName: "checkmark.circle.fill")
						} else {
							ProgressView().controlSize(.mini)
						}
						Text(processingPhase.compactTitle)
					}
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(AppStyle.accent)
					.tint(AppStyle.accent)
				}
			}
		}
	}
}
