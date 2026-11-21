import Foundation
import WispCore

let watchdogSeconds = 25
DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(watchdogSeconds)) {
    FileHandle.standardError.write(Data("o Mac demorou demais para responder (mais de \(watchdogSeconds) s); um texto digitado pela metade pode ter ficado no campo\n".utf8))
    exit(MacError.timeout)
}

let outcome = MacControlService(driver: AXMacDriver()).run(arguments: Array(CommandLine.arguments.dropFirst()))
if !outcome.stdout.isEmpty { print(outcome.stdout) }
if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data((outcome.stderr + "\n").utf8)) }
exit(outcome.exitCode)
