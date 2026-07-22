import SwiftUI
import UIKit

struct EntryView: View {
	@Bindable var store: JournalStore
	let entry: JournalEntry
	let onClose: () -> Void
	let onRerecord: () -> Void

	@State private var showsDeleteConfirmation = false
	@State private var showsContext = false

	private var currentEntry: JournalEntry {
		store.entry(id: entry.id) ?? entry
	}

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			ScrollView {
				VStack(alignment: .leading, spacing: 28) {
					HStack {
						InvisibleCloseControl(action: onClose)
							.offset(x: -14)
						Spacer()
						Text(currentEntry.createdAt.formatted(Date.FormatStyle.slateEntryHeader))
							.font(.system(size: 11))
							.foregroundStyle(Color.white.opacity(0.76))
						Spacer()
						Color.clear.frame(width: 30, height: 44)
					}
					.padding(.top, 8)
					.padding(.bottom, 8)

					SlateCard {
						VStack(alignment: .leading, spacing: 17) {
							ForEach(currentEntry.observations, id: \.self) { observation in
								Text(observation)
									.font(.system(size: 17, weight: .regular))
									.foregroundStyle(.white)
									.fixedSize(horizontal: false, vertical: true)
							}

							if !currentEntry.tags.isEmpty {
								FlowLayout(spacing: 5) {
									ForEach(currentEntry.tags, id: \.self) { SlateTag(text: $0) }
								}
							}
						}
					}

					Button { showsContext = true } label: {
						Label("Not what you meant? Add context.", systemImage: "arrow.uturn.backward")
							.font(.system(size: 10))
							.foregroundStyle(Color.white.opacity(0.20))
					}
					.buttonStyle(.plain)

					SlateCard {
						VStack(alignment: .leading, spacing: 10) {
							Text("This becomes your week.")
								.font(.system(size: 13, weight: .semibold))
							Text("On Sunday, Slate reads the week back. What repeated, what shifted. You don’t have to do anything.")
								.font(.system(size: 12))
								.lineSpacing(2)
								.foregroundStyle(Color.white.opacity(0.40))
							Text("Got it")
								.font(.system(size: 11))
								.padding(.top, 5)
						}
					}

					if let context = currentEntry.context, !context.isEmpty {
						VStack(alignment: .leading, spacing: 7) {
							Text("Context")
								.font(.system(size: 9))
								.foregroundStyle(SlateStyle.tertiary)
							Text(context)
								.font(.system(size: 13))
								.foregroundStyle(Color.white.opacity(0.70))
						}
					}

					if store.settings.showTranscripts {
						Text(currentEntry.transcript)
							.font(.system(size: 14))
							.foregroundStyle(Color.white.opacity(0.84))
							.lineSpacing(6)
							.textSelection(.enabled)
					}
				}
				.padding(.horizontal, 30)
				.padding(.bottom, 36)
			}
			.scrollIndicators(.hidden)
		}
		.safeAreaInset(edge: .bottom) { bottomBar }
		.presentationBackground(.black)
		.sheet(isPresented: $showsContext) {
			ContextSheet(store: store, entryID: entry.id)
		}
		.alert("Delete this entry?", isPresented: $showsDeleteConfirmation) {
			Button("Cancel", role: .cancel) {}
			Button("Delete", role: .destructive) {
				store.delete(currentEntry)
				onClose()
			}
		} message: {
			Text("The recording, transcript, and reflection will be removed from this device.")
		}
	}

	private var bottomBar: some View {
		HStack(spacing: 22) {
			Button(action: onRerecord) {
				Label("Re-record", systemImage: "mic.fill")
			}
			Button { showsDeleteConfirmation = true } label: {
				Label("Delete entry", systemImage: "trash")
			}
			Button(action: copyEntry) {
				Label("Copy", systemImage: "doc.on.doc")
			}
		}
		.font(.system(size: 10))
		.foregroundStyle(Color.white.opacity(0.22))
		.frame(maxWidth: .infinity)
		.padding(.vertical, 13)
		.background(.black.opacity(0.94))
	}

	private func copyEntry() {
		let text = ([currentEntry.headline] + currentEntry.observations + [currentEntry.transcript]).joined(separator: "\n\n")
		UIPasteboard.general.string = text
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
					Text("Add whatever changes the meaning. This stays on your device too.")
						.font(.system(size: 13))
						.foregroundStyle(SlateStyle.secondary)
					TextEditor(text: $context)
						.font(.system(size: 15))
						.scrollContentBackground(.hidden)
						.padding(12)
						.background(SlateStyle.card, in: RoundedRectangle(cornerRadius: 13))
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
					Button("Reflect again") {
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
