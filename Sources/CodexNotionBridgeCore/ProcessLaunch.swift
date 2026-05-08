import Foundation

enum ProcessLaunch {
    static func executableAndArguments(command: String, arguments: [String]) -> (URL, [String]) {
        if command.contains("/") {
            return (URL(fileURLWithPath: command), arguments)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), [command] + arguments)
    }
}
