import Foundation

public enum TerminationSignal {
    public static func routeToHandler() {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        sigaction(SIGTERM, &action, nil)
    }
}
