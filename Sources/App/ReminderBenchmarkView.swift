import Observation
import SwiftUI

@MainActor
@Observable
final class ReminderBenchmarkSession {
	private(set) var run: ReminderBenchmarkRun?
	private(set) var activeGroup: ReminderBenchmarkGroup?
	private(set) var isRunning = false
	@ObservationIgnored private var task: Task<Void, Never>?
	@ObservationIgnored private var generation = UUID()

	deinit { task?.cancel() }

	func start(groups: [ReminderBenchmarkGroup], services: ReminderBenchmarkServices = .live) {
		guard !isRunning else { return }
		let id = UUID()
		generation = id
		isRunning = true
		run = ReminderBenchmarkRun(results: [], checks: [], status: .complete, total: groups.reduce(0) { $0 + $1.cases.count })
		activeGroup = groups.first
		task = Task { [weak self] in
			let result = await ReminderBenchmark.run(groups: groups, services: services) { [weak self] progress in
				guard let self, self.generation == id else { return }
				self.run = progress.run
				self.activeGroup = progress.group
			}
			guard let self, self.generation == id else { return }
			self.run = result
			self.activeGroup = nil
			self.isRunning = false
			self.task = nil
		}
	}

	func cancel() {
		guard isRunning else { return }
		generation = UUID()
		let oldTask = task
		task = nil
		oldTask?.cancel()
		isRunning = false
		activeGroup = nil
		run?.status = .cancelled
		run?.stopReason = "Stopped by you. Only assessed cases are included in the results."
	}
}

struct ReminderBenchmarkView: View {
	@State private var session = ReminderBenchmarkSession()

	var body: some View {
		List {
			Section {
				VStack(alignment: .leading, spacing: 8) {
					Text(ReminderBenchmark.modelStatus)
						.font(.subheadline)
					Text("\(ReminderBenchmarkCorpus.caseCount) model-backed cases in \(ReminderBenchmarkCorpus.groups.count) levels, plus deterministic contract checks.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Button { session.start(groups: ReminderBenchmarkCorpus.groups) } label: {
					Label("Run full benchmark", systemImage: "play.fill")
				}
				.disabled(session.isRunning || !ReminderBenchmark.canRun)
				Button("Run deterministic checks") { session.start(groups: []) }
					.disabled(session.isRunning)
				if session.isRunning {
					ProgressView(value: Double(session.run?.assessed ?? 0), total: Double(max(session.run?.total ?? 0, 1))) {
						Text(session.activeGroup.map { "Level \($0.level) · \($0.title)" } ?? "Checking contracts")
					} currentValueLabel: {
						Text("\(session.run?.assessed ?? 0) assessed of \(session.run?.total ?? 0)")
					}
					Button("Cancel run", role: .cancel) { session.cancel() }
				}
			} footer: {
				Text("Runs entirely on this device using the production parser and system language model, without the app’s matching cache. A full run can take several minutes.")
			}

			if let run = session.run, !session.isRunning { summarySection(run) }

			ForEach(ReminderBenchmarkCorpus.groups) { group in
				Section {
					Text("Level \(group.level) · \(group.title)").font(.headline)
					Button { session.start(groups: [group]) } label: {
						Label("Run \(group.cases.count) cases", systemImage: "play")
					}
					.disabled(session.isRunning || !ReminderBenchmark.canRun)
					ForEach(results(for: group)) { result in
						NavigationLink { ReminderBenchmarkResultView(result: result) } label: {
							HStack(spacing: 10) {
								Image(systemName: result.isAssessed ? (result.passed ? "checkmark.circle.fill" : "xmark.circle.fill") : "minus.circle")
									.foregroundStyle(result.isAssessed ? (result.passed ? Color.green : .red) : .secondary)
								VStack(alignment: .leading, spacing: 2) {
									Text(result.name)
									Text(result.isAssessed ? result.duration.formatted(.number.precision(.fractionLength(1))) + " seconds" : "Not assessed")
										.font(.caption)
										.foregroundStyle(.secondary)
								}
							}
						}
					}
				} footer: { Text(group.detail) }
			}

			if let run = session.run, !run.checks.isEmpty {
				Section {
					Text("Deterministic contract checks").font(.headline)
					ForEach(run.checks) { check in
						Label(check.name, systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
							.foregroundStyle(check.passed ? .green : .red)
					}
				}
			}
		}
		.listStyle(.plain)
		.scrollContentBackground(.hidden)
		.background(AppStyle.background)
		.navigationTitle("Reminder Benchmark")
		.navigationBarTitleDisplayMode(.inline)
		.onDisappear { session.cancel() }
		#if DEBUG
		.task {
			let arguments = ProcessInfo.processInfo.arguments
			if arguments.contains("-demo-benchmark-cancelled") {
				session.start(groups: ReminderBenchmarkContractChecks.previewGroups, services: ReminderBenchmarkContractChecks.previewServices(status: .cancelled))
			} else if arguments.contains("-demo-benchmark-unavailable") {
				session.start(groups: ReminderBenchmarkContractChecks.previewGroups, services: ReminderBenchmarkContractChecks.previewServices(status: .unavailable))
			} else if arguments.contains("-demo-benchmark-failed") {
				session.start(groups: ReminderBenchmarkContractChecks.previewGroups, services: ReminderBenchmarkContractChecks.previewServices(status: .failed))
			}
		}
		#endif
	}

	private func summarySection(_ run: ReminderBenchmarkRun) -> some View {
		let summary = run.summary
		return Section {
			Text(run.status == .complete ? "Latest run" : "Partial results").font(.headline)
			LabeledContent("Run", value: run.status.title)
			Text("\(run.assessed) assessed · \(run.attempted) attempted · \(run.total) total")
				.font(.subheadline)
			if let reason = run.stopReason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
			LabeledContent("Exact cases", value: summary.cases == 0 ? "Not assessed" : "\(summary.casePasses)/\(summary.cases)")
			LabeledContent("Cue precision", value: ReminderBenchmarkSummary.percentage(summary.cuePrecision))
			LabeledContent("Cue recall", value: ReminderBenchmarkSummary.percentage(summary.cueRecall))
			LabeledContent("Schema fields", value: ReminderBenchmarkSummary.percentage(summary.fieldAccuracy))
			LabeledContent("Evidence grounding", value: ReminderBenchmarkSummary.percentage(summary.evidenceGrounding))
			if summary.resolutionCases > 0 { LabeledContent("Fuzzy resolution", value: "\(summary.resolutionPasses)/\(summary.resolutionCases)") }
			LabeledContent("Contract checks", value: "\(summary.checkPasses)/\(summary.checks)")
		}
	}

	private func results(for group: ReminderBenchmarkGroup) -> [ReminderBenchmarkCaseResult] {
		session.run?.results.filter { $0.groupID == group.id } ?? []
	}
}

private struct ReminderBenchmarkResultView: View {
	let result: ReminderBenchmarkCaseResult

	var body: some View {
		List {
			Section {
				LabeledContent("Result", value: result.isAssessed ? (result.passed ? "Pass" : "Fail") : "Not assessed")
				.foregroundStyle(result.isAssessed ? (result.passed ? Color.green : Color.red) : Color.secondary)
				LabeledContent("Duration", value: result.duration.formatted(.number.precision(.fractionLength(1))) + " seconds")
				if result.isAssessed { LabeledContent("Cues", value: "\(result.matchedCount)/\(result.expectedCount) matched") }
				if result.fieldChecks > 0 {
					LabeledContent("Schema fields", value: "\(result.fieldPasses)/\(result.fieldChecks)")
				}
			}

			if !result.generated.isEmpty {
				Section {
					Text("Generated").font(.headline)
					ForEach(result.generated, id: \.self) {
						Text($0)
							.textSelection(.enabled)
					}
				}
			}

			if !result.issues.isEmpty {
				Section {
					Text("Issues").font(.headline)
					ForEach(result.issues, id: \.self) {
						Text($0)
							.foregroundStyle(result.isAssessed ? Color.red : Color.secondary)
					}
				}
			}
		}
		.listStyle(.plain)
		.scrollContentBackground(.hidden)
		.background(AppStyle.background)
		.navigationTitle(result.name)
		.navigationBarTitleDisplayMode(.inline)
	}
}
