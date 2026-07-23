import SwiftUI

struct JournalView: View {
	@Bindable var store: JournalStore
	let onSelectEntry: (JournalEntry) -> Void
	let onNewRecording: () -> Void
	let onReview: () -> Void
	let onSettings: () -> Void

	@State private var entryPendingDeletion: JournalEntry?

	private var visibleEntries: [JournalEntry] {
		store.entries(onOrBefore: store.selectedDate)
	}

	private var groupedEntries: [(date: Date, entries: [JournalEntry])] {
		let grouped = Dictionary(grouping: visibleEntries) { Calendar.current.startOfDay(for: $0.createdAt) }
		return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.createdAt > $1.createdAt }) }
	}

	var body: some View {
		ZStack(alignment: .bottomTrailing) {
			Color.black.ignoresSafeArea()

			List {
				VStack(alignment: .leading, spacing: 0) {
					header
					WeekStrip(selectedDate: $store.selectedDate, entries: store.entries)
						.padding(.top, 16)
						.padding(.bottom, 18)
						.contentShape(Rectangle())
						.simultaneousGesture(weekSwipeGesture)
				}
				.padding(.horizontal, 20)
				.listRowInsets(EdgeInsets())
				.listRowBackground(Color.black)
				.listRowSeparator(.hidden)

				if groupedEntries.isEmpty {
					emptyState
						.listRowInsets(EdgeInsets())
						.listRowBackground(Color.black)
						.listRowSeparator(.hidden)
				} else {
					ForEach(groupedEntries, id: \.date) { group in
						if !Calendar.current.isDate(group.date, inSameDayAs: store.selectedDate) {
							Text(group.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
								.font(.system(size: 13, weight: .medium))
								.foregroundStyle(AppStyle.secondary)
								.listRowInsets(EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 20))
								.listRowBackground(Color.black)
								.listRowSeparator(.hidden)
						}

						ForEach(group.entries) { entry in
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

			Button(action: onNewRecording) {
				Label("New", systemImage: "mic.fill")
					.font(.system(size: 14, weight: .medium))
					.foregroundStyle(.white)
					.padding(.horizontal, 27)
					.frame(height: 50)
					.background(AppStyle.accent, in: Capsule())
					.shadow(color: AppStyle.accent.opacity(0.34), radius: 18, y: 8)
			}
			.buttonStyle(.plain)
			.padding(.trailing, 20)
			.padding(.bottom, 18)
			.accessibilityHint("Starts a voice memo")
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
		VStack(alignment: .leading, spacing: 20) {
			HStack {
				Spacer()

				HStack(spacing: 0) {
					Button(action: onReview) {
						Image(systemName: "calendar")
							.font(.system(size: 17, weight: .regular))
							.frame(width: 44, height: 39)
					}
					.accessibilityLabel("Weekly review")

					Rectangle()
						.fill(Color.white.opacity(0.10))
						.frame(width: 0.5, height: 18)

					Button(action: onSettings) {
						Image(systemName: "gearshape")
							.font(.system(size: 17, weight: .regular))
							.frame(width: 44, height: 39)
					}
					.accessibilityLabel("Settings")
				}
				.foregroundStyle(Color.white.opacity(0.88))
				.glassEffect(.regular.interactive(), in: Capsule())
			}

			Text(store.selectedDate.formatted(Date.FormatStyle.journalHeader))
				.font(.system(size: 32, weight: .regular))
				.foregroundStyle(.white)
				.contentTransition(.numericText())
		}
		.padding(.top, 8)
	}

	private var emptyState: some View {
		VStack(spacing: 12) {
			Text("No voice memos")
				.font(.system(size: 21, weight: .medium))
			Text("Tap New to record.")
				.font(.system(size: 15))
				.foregroundStyle(AppStyle.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 270)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 112)
	}

	private var weekSwipeGesture: some Gesture {
		DragGesture(minimumDistance: 32)
			.onEnded { value in
				guard abs(value.translation.width) > 90,
					abs(value.translation.width) > abs(value.translation.height) * 1.35
				else { return }
				let days = value.translation.width < 0 ? 7 : -7
				guard let date = Calendar.current.date(byAdding: .day, value: days, to: store.selectedDate) else { return }
				withAnimation(.easeOut(duration: 0.22)) { store.selectedDate = date }
			}
	}
}

private struct EntryCard: View {
	let entry: JournalEntry
	let processingPhase: EntryProcessingPhase?

	var body: some View {
		AppCard {
			VStack(alignment: .leading, spacing: 12) {
				HStack(spacing: 5) {
					Text(entry.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
					Text("·")
					Text(entry.duration.compactDurationText)
					Spacer()
					Image(systemName: "waveform")
						.font(.system(size: 12))
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

private struct WeekStrip: View {
	@Binding var selectedDate: Date
	let entries: [JournalEntry]

	private var dates: [Date] {
		let calendar = Calendar.current
		let weekday = calendar.component(.weekday, from: selectedDate)
		let daysSinceMonday = (weekday + 5) % 7
		let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: calendar.startOfDay(for: selectedDate)) ?? selectedDate
		return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
	}

	var body: some View {
		HStack(spacing: 6) {
			ForEach(dates, id: \.self) { date in
				let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
				let hasEntry = entries.contains { Calendar.current.isDate($0.createdAt, inSameDayAs: date) }
				Button {
					withAnimation(.easeOut(duration: 0.16)) { selectedDate = date }
				} label: {
					VStack(spacing: 5) {
						Text(date.formatted(.dateTime.weekday(.narrow)))
							.font(.system(size: 12, weight: .medium))
						Text(date.formatted(.dateTime.day()))
							.font(.system(size: 16, weight: .semibold))
						Circle()
							.fill(hasEntry ? AppStyle.accent : Color.clear)
							.frame(width: 4, height: 4)
					}
					.foregroundStyle(isSelected ? Color.white : AppStyle.secondary)
					.frame(maxWidth: .infinity)
					.frame(height: 64)
					.background(isSelected ? AppStyle.card : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
					.overlay {
						RoundedRectangle(cornerRadius: 9, style: .continuous)
							.stroke(isSelected ? AppStyle.accent.opacity(0.85) : AppStyle.cardBorder, lineWidth: 0.8)
					}
				}
				.buttonStyle(.plain)
				.accessibilityLabel(date.formatted(date: .complete, time: .omitted))
			}
		}
	}
}
