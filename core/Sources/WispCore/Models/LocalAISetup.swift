import Foundation

public enum LocalAIStep: Equatable, Sendable {
    case pull(String)
    case use(String)
    case selectEngine
}

public enum LocalAIStepResult: Equatable, Sendable {
    case done
    case failed(String)
    case cancelled
}

public enum LocalAIOutcome: Equatable, Sendable {
    case done
    case failed(String)
    case cancelled
}

public enum LocalAISetup {
    public static func steps(modelInstalled: Bool, tag: String) -> [LocalAIStep] {
        (modelInstalled ? [] : [.pull(tag)]) + [.use(tag), .selectEngine]
    }

    public static func preflight(model: LocalModel, hardware: HardwareProfile, diskMargin: UInt64, installed: Bool) -> String? {
        guard LocalAdvisor.appleSilicon(hardware.chip) else { return LocalAdvisor.needsAppleSilicon }
        let fit = ModelFit.assess(model, on: hardware, diskMargin: diskMargin, installed: installed)
        if let short = fit.diskShortBy {
            return "Falta espaço em disco: faltam \(ModelFit.gigabytes(short)) livres para baixar o \(model.name)."
        }
        if fit.level == .doesNotFit { return "O \(model.name) não cabe na memória deste Mac." }
        return nil
    }

    public static func run(
        _ steps: [LocalAIStep], perform: @MainActor (LocalAIStep) async -> LocalAIStepResult
    ) async -> LocalAIOutcome {
        for step in steps {
            switch await perform(step) {
            case .done: continue
            case .failed(let message): return .failed(message)
            case .cancelled: return .cancelled
            }
        }
        return .done
    }
}
