import Foundation
import HUDKit

// `__REPO__ <command> [key=value ...]`: talks to __PRODUCT__'s MacHUD control socket.
//
//   __REPO__ hello
//   __REPO__ say text="hi there"
//   __REPO__ panel toggle id=main
//   __REPO__ settings set showCount=0
//   __REPO__ quit

let usage = """
usage: __REPO__ <command> [key=value ...]
  hello | state | help | quit
  panel show|hide|toggle id=main
  panel frame id=main x= y= w= h=
  say [text=]                        change what the panel says (empty: back to the greeting)
  settings get [key=]  |  settings set key=value ...

Environment: __REPO_UPPER___SOCKET picks the socket name (default __REPO__).

"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !["-h", "--help"].contains(command) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 2 : 0)
}

let socketName = ProcessInfo.processInfo.environment["__REPO_UPPER___SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "__REPO__"

switch command {
case "say":
    // Shorthand for `action name=say ...`.
    arguments = ["action", "name=say"] + arguments.dropFirst()
case "settings" where arguments.count > 1 && ["get", "set"].contains(arguments[1]):
    // The sub-verb travels as `action=` so the router does not read a positional as a key.
    arguments[1] = "action=\(arguments[1])"
default:
    break
}

exit(HUDSocketClient.runCLI(path: HUDSocket.path(for: socketName), arguments: arguments, appName: "__REPO__"))
