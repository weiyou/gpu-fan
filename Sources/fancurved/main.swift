import Foundation
import FanCore

// Entry point. Runs the blocking control loop; install/uninstall is handled by
// `fancurvectl`. Pass --foreground to also echo logs to stdout for testing:
//   sudo fancurved --foreground
let daemon = Daemon(foreground: CommandLine.arguments.contains("--foreground"))
gDaemon = daemon
installFailsafes()
daemon.run()
