import Darwin
import Foundation
import DefaultAppCore
import DefaultAppCLIKit

@main
struct DefaultAppCommandLineTool {
    static func main() async {
        let status = await CLIApplication().run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            service: HandlerService(),
            output: StandardCLIOutputSink()
        )
        exit(status)
    }
}
