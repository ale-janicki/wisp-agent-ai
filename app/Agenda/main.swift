import Foundation
import WispCore

let outcome = await AgendaService(store: EventKitStore()).run(arguments: Array(CommandLine.arguments.dropFirst()))
if !outcome.stdout.isEmpty { print(outcome.stdout) }
if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data((outcome.stderr + "\n").utf8)) }
exit(outcome.exitCode)
