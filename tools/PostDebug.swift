import AppKit

// Usage: swift tools/PostDebug.swift action=open entry=<uuid> [key=value ...]
var info: [String: String] = [:]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let pair = args.removeFirst()
    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    if kv.count == 2 { info[String(kv[0])] = String(kv[1]) }
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.cyb.tmuxmanager.debug"),
    object: nil, userInfo: info, deliverImmediately: true)
print("posted \(info)")
