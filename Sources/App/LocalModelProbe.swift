#if DEBUG
import Darwin
import Foundation
import FoundationModels

@MainActor
enum LocalModelProbe {
	static func runFromLaunchArguments() async {
		let arguments = ProcessInfo.processInfo.arguments
		guard let prompt = argument(after: "-local-model-prompt", in: arguments) else { return }

		print("LOCAL_MODEL_PROBE_BEGIN")
		fflush(stdout)
		switch SystemLanguageModel.default.availability {
		case .available:
			do {
				let response = try await ServiceAdmission.model.run(timeout: .seconds(45)) {
					try await LanguageModelSession().respond(to: prompt).content
				}
				finish(response, status: 0)
			} catch {
				finish("ERROR: \(error.localizedDescription)", status: 1)
			}
		case let .unavailable(reason):
			finish("ERROR: SystemLanguageModel.default is unavailable: \(reason)", status: 1)
		}
	}

	private static func finish(_ output: String, status: Int32) -> Never {
		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("local-model-probe.txt")
		try? output.write(to: outputURL, atomically: true, encoding: .utf8)
		print(output)
		print("LOCAL_MODEL_PROBE_END")
		fflush(stdout)
		exit(status)
	}

	private static func argument(after flag: String, in arguments: [String]) -> String? {
		guard let index = arguments.firstIndex(of: flag),
			arguments.indices.contains(index + 1)
		else { return nil }
		return arguments[index + 1]
	}
}
#endif
