import SwiftUI

struct ReminderBenchmarkView: View {
	@State private var run: ReminderBenchmarkRun?
	@State private var completed = 0
	@State private var total = ReminderBenchmarkCorpus.caseCount
	@State private var activeGroup: ReminderBenchmarkGroup?
	@State private var isRunning = false

	var body: some View {
		List {
			Section {
				VStack(alignment: .leading, spacing: 8) {
					Text(ReminderBenchmark.modelStatus)
						.font(.subheadline)
					Text("\(ReminderBenchmarkCorpus.caseCount) model-backed cases in \(ReminderBenchmarkCorpus.groups.count) levels, plus 8 deterministic contract checks.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				Button {
					start(groups: ReminderBenchmarkCorpus.groups)
				} label: {
					Label("Run full benchmark", systemImage: "play.fill")
				}
				.disabled(isRunning || !ReminderBenchmark.canRun)

				if isRunning {
					ProgressView(value: Double(completed), total: Double(max(total, 1))) {
						Text(activeGroup.map { "Level \($0.level) · \($0.title)" } ?? "Preparing")
					} currentValueLabel: {
						Text("\(completed) of \(total)")
					}
				}
			} footer: {
				Text("Runs entirely on this device using the production parser and system language model. A full run can take several minutes.")
			}

			if let run {
				summarySection(run.summary)
			}

			ForEach(ReminderBenchmarkCorpus.groups) { group in
				Section {
					Button {
						start(groups: [group])
					} label: {
						Label("Run \(group.cases.count) cases", systemImage: "play")
					}
					.disabled(isRunning || !ReminderBenchmark.canRun)

					ForEach(results(for: group)) { result in
						NavigationLink {
							ReminderBenchmarkResultView(result: result)
						} label: {
							HStack(spacing: 10) {
								Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
									.foregroundStyle(result.passed ? .green : .red)
								VStack(alignment: .leading, spacing: 2) {
									Text(result.name)
									Text(result.duration.formatted(.number.precision(.fractionLength(1))) + " seconds")
										.font(.caption)
										.foregroundStyle(.secondary)
								}
							}
						}
					}
				} header: {
					Text("Level \(group.level) · \(group.title)")
				} footer: {
					Text(group.detail)
				}
			}

			if let run, !run.checks.isEmpty {
				Section("Deterministic contract checks") {
					ForEach(run.checks) { check in
						Label(
							check.name,
							systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
						)
						.foregroundStyle(check.passed ? .green : .red)
					}
				}
			}
		}
		.navigationTitle("Reminder Benchmark")
		.navigationBarTitleDisplayMode(.inline)
	}

	@ViewBuilder
	private func summarySection(_ summary: ReminderBenchmarkSummary) -> some View {
		Section("Latest run") {
			LabeledContent("Exact cases", value: "\(summary.casePasses)/\(summary.cases)")
			LabeledContent("Cue precision", value: summary.cuePrecision.formatted(.percent.precision(.fractionLength(1))))
			LabeledContent("Cue recall", value: summary.cueRecall.formatted(.percent.precision(.fractionLength(1))))
			LabeledContent("Schema fields", value: summary.fieldAccuracy.formatted(.percent.precision(.fractionLength(1))))
			LabeledContent("Evidence grounding", value: summary.evidenceGrounding.formatted(.percent.precision(.fractionLength(1))))
			if summary.resolutionCases > 0 {
				LabeledContent("Fuzzy resolution", value: "\(summary.resolutionPasses)/\(summary.resolutionCases)")
			}
			LabeledContent("Contract checks", value: "\(summary.checkPasses)/\(summary.checks)")
		}
	}

	private func results(for group: ReminderBenchmarkGroup) -> [ReminderBenchmarkCaseResult] {
		run?.results.filter { $0.groupID == group.id } ?? []
	}

	private func start(groups: [ReminderBenchmarkGroup]) {
		guard !isRunning else { return }
		isRunning = true
		run = nil
		completed = 0
		total = groups.reduce(0) { $0 + $1.cases.count }
		activeGroup = groups.first

		Task {
			let completedRun = await ReminderBenchmark.run(groups: groups) { progress in
				completed = progress.completed
				total = progress.total
				activeGroup = progress.group
			}
			run = completedRun
			isRunning = false
			activeGroup = nil
		}
	}
}

private struct ReminderBenchmarkResultView: View {
	let result: ReminderBenchmarkCaseResult

	var body: some View {
		List {
			Section {
				LabeledContent("Result", value: result.passed ? "Pass" : "Fail")
				.foregroundStyle(result.passed ? .green : .red)
				LabeledContent("Duration", value: result.duration.formatted(.number.precision(.fractionLength(1))) + " seconds")
				LabeledContent("Cues", value: "\(result.matchedCount)/\(result.expectedCount) matched")
				if result.fieldChecks > 0 {
					LabeledContent("Schema fields", value: "\(result.fieldPasses)/\(result.fieldChecks)")
				}
			}

			if !result.generated.isEmpty {
				Section("Generated") {
					ForEach(result.generated, id: \.self) {
						Text($0)
							.textSelection(.enabled)
					}
				}
			}

			if !result.issues.isEmpty {
				Section("Issues") {
					ForEach(result.issues, id: \.self) {
						Text($0)
							.foregroundStyle(.red)
					}
				}
			}
		}
		.navigationTitle(result.name)
		.navigationBarTitleDisplayMode(.inline)
	}
}
