import SwiftUI

struct JournalView: View {
	@Bindable var store: JournalStore
	let onSelectEntry: (JournalEntry) -> Void
	let onNewRecording: () -> Void
	let onReview: () -> Void
	let onSettings: () -> Void

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

			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					header
					WeekStrip(selectedDate: $store.selectedDate, entries: store.entries)
						.padding(.top, 16)
						.padding(.bottom, 18)

					if groupedEntries.isEmpty {
						emptyState
					} else {
						ForEach(groupedEntries, id: \.date) { group in
							entrySection(date: group.date, entries: group.entries)
						}
					}
				}
				.padding(.horizontal, 20)
				.padding(.bottom, 104)
			}
			.scrollIndicators(.hidden)

			Button(action: onNewRecording) {
				Label("New", systemImage: "mic.fill")
					.font(.system(size: 14, weight: .medium))
					.foregroundStyle(.white)
					.padding(.horizontal, 27)
					.frame(height: 50)
					.background(SlateStyle.accent, in: Capsule())
					.shadow(color: SlateStyle.accent.opacity(0.28), radius: 18, y: 8)
			}
			.buttonStyle(.plain)
			.padding(.trailing, 20)
			.padding(.bottom, 18)
			.accessibilityHint("Starts a private voice journal entry")
		}
		.simultaneousGesture(weekSwipeGesture)
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
				.foregroundStyle(Color.white.opacity(0.68))
				.glassEffect(.regular.interactive(), in: Capsule())
			}

			Text(store.selectedDate.formatted(Date.FormatStyle.slateHeader))
				.font(.system(size: 32, weight: .regular))
				.foregroundStyle(.white)
				.contentTransition(.numericText())
		}
		.padding(.top, 8)
	}

	private var emptyState: some View {
		VStack(spacing: 12) {
			Text("Speak your mind")
				.font(.system(size: 19, weight: .regular))
			Text("A private recording and reflection will live here. Nothing leaves this device.")
				.font(.system(size: 13))
				.foregroundStyle(SlateStyle.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 270)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 112)
	}

	private func entrySection(date: Date, entries: [JournalEntry]) -> some View {
		VStack(alignment: .leading, spacing: 9) {
			if !Calendar.current.isDate(date, inSameDayAs: store.selectedDate) {
				Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
					.font(.system(size: 9, weight: .regular))
					.foregroundStyle(SlateStyle.tertiary)
					.padding(.top, 9)
			}

			ForEach(entries) { entry in
				Button { onSelectEntry(entry) } label: {
					EntryCard(entry: entry, processingPhase: store.processingPhase(for: entry.id))
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.bottom, 7)
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
		SlateCard {
			VStack(alignment: .leading, spacing: 12) {
				HStack(spacing: 5) {
					Text(entry.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
					Text("·")
					Text(entry.duration.compactDurationText)
					Spacer()
					Image(systemName: "waveform")
						.font(.system(size: 10))
				}
				.font(.system(size: 9))
				.foregroundStyle(SlateStyle.tertiary)

				Text(entry.headline)
					.font(.system(size: 17, weight: .regular))
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
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(SlateStyle.accent)
					.tint(SlateStyle.accent)
				}

				if !entry.tags.isEmpty {
					FlowLayout(spacing: 5) {
						ForEach(entry.tags.prefix(3), id: \.self) { SlateTag(text: $0) }
					}
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
							.font(.system(size: 9))
						Text(date.formatted(.dateTime.day()))
							.font(.system(size: 13, weight: .medium))
						Circle()
							.fill(hasEntry ? SlateStyle.accent : Color.clear)
							.frame(width: 3, height: 3)
					}
					.foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
					.frame(maxWidth: .infinity)
					.frame(height: 58)
					.background(Color.white.opacity(isSelected ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
					.overlay {
						RoundedRectangle(cornerRadius: 9, style: .continuous)
							.stroke(isSelected ? SlateStyle.accent.opacity(0.65) : Color.white.opacity(0.055), lineWidth: 0.7)
					}
				}
				.buttonStyle(.plain)
				.accessibilityLabel(date.formatted(date: .complete, time: .omitted))
			}
		}
	}
}
