import MapKit
import SwiftUI

struct EntryView: View {
	@Bindable var store: JournalStore
	let entry: JournalEntry

	@State private var showsContext = false

	private var currentEntry: JournalEntry {
		store.entry(id: entry.id) ?? entry
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
						Spacer(minLength: 12)
						Text(currentEntry.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
							.font(.system(size: 14, weight: .medium))
							.foregroundStyle(AppStyle.secondary)
							.lineLimit(1)
					}
					.padding(.top, 10)

					if let phase = store.processingPhase(for: entry.id) {
						EntryProcessingStatusView(phase: phase)
							.transition(.move(edge: .top).combined(with: .opacity))
					}

					VStack(alignment: .leading, spacing: 16) {
						Text("Summary")
							.font(.system(size: 15, weight: .semibold))
							.foregroundStyle(AppStyle.secondary)

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
							ModelAttribution(label: "Summary", model: model)
						}

						if !currentEntry.tags.isEmpty {
							FlowLayout(spacing: 7) {
								ForEach(currentEntry.tags, id: \.self) { TagPill(text: $0) }
							}
						}
					}

					Button { showsContext = true } label: {
						Label("Add context", systemImage: "text.badge.plus")
							.font(.system(size: 15, weight: .medium))
							.foregroundStyle(AppStyle.accent)
					}
					.buttonStyle(.plain)

					if let context = currentEntry.context, !context.isEmpty {
						VStack(alignment: .leading, spacing: 9) {
							Text("Context")
								.font(.system(size: 15, weight: .semibold))
								.foregroundStyle(AppStyle.secondary)
							Text(context)
								.font(.system(size: 16))
								.foregroundStyle(Color.white.opacity(0.90))
								.lineSpacing(4)
						}
					}

					if store.settings.showTranscripts, !currentEntry.transcript.isEmpty {
						VStack(alignment: .leading, spacing: 12) {
							Text("Transcript")
								.font(.system(size: 15, weight: .semibold))
								.foregroundStyle(AppStyle.secondary)
							ExpandableTranscript(text: currentEntry.transcript)
								.contentTransition(.opacity)

							if let model = currentEntry.transcriptModel {
								ModelAttribution(label: "Transcript", model: model)
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
		.sheet(isPresented: $showsContext) {
			ContextSheet(store: store, entryID: entry.id)
		}
	}
}

private struct ModelAttribution: View {
	let label: String
	let model: String

	var body: some View {
		Text("\(label) · \(model)")
			.font(.system(size: 12, weight: .medium))
			.foregroundStyle(AppStyle.tertiary)
			.frame(maxWidth: .infinity, alignment: .trailing)
	}
}

private struct ExpandableTranscript: View {
	let text: String
	@State private var isExpanded = false

	private var isTruncated: Bool {
		text.count > 140 || text.split(separator: "\n").count > 4
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

			Map(
				initialPosition: .region(MKCoordinateRegion(
					center: coordinate,
					latitudinalMeters: 2_400,
					longitudinalMeters: 2_400
				)),
				interactionModes: [.pan, .zoom]
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

private struct ContextSheet: View {
	@Environment(\.dismiss) private var dismiss
	@Bindable var store: JournalStore
	let entryID: UUID
	@State private var context = ""

	var body: some View {
		NavigationStack {
			ZStack {
				Color.black.ignoresSafeArea()
				VStack(alignment: .leading, spacing: 14) {
					Text("Context")
						.font(.system(size: 15, weight: .semibold))
						.foregroundStyle(AppStyle.secondary)
					TextEditor(text: $context)
						.font(.system(size: 16))
						.scrollContentBackground(.hidden)
						.padding(12)
						.background(AppStyle.card, in: RoundedRectangle(cornerRadius: 13))
						.overlay {
							RoundedRectangle(cornerRadius: 13)
								.stroke(AppStyle.cardBorder, lineWidth: 0.8)
						}
						.frame(minHeight: 150)
				}
				.padding(20)
			}
			.navigationTitle("Add context")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Update summary") {
						Task {
							await store.addContext(context, to: entryID)
							dismiss()
						}
					}
					.disabled(context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				}
			}
		}
		.presentationBackground(.black)
		.overlay {
			if store.isProcessing { ProcessingOverlay(message: store.processingMessage) }
		}
	}
}
