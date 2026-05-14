import Foundation

@objc protocol CaffeinateHelperProtocol {
    func setDisableSleep(_ disable: Bool, reply: @escaping (String?) -> Void)
}

final class HelperImpl: NSObject, CaffeinateHelperProtocol {
    func setDisableSleep(_ disable: Bool, reply: @escaping (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disable ? "1" : "0"]
        do {
            try process.run()
            process.waitUntilExit()
            reply(process.terminationStatus == 0 ? nil : "pmset exited \(process.terminationStatus)")
        } catch {
            reply(error.localizedDescription)
        }
    }
}

final class HelperListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: CaffeinateHelperProtocol.self)
        conn.exportedObject = HelperImpl()
        conn.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: "gen.caffeinate.helper")
let delegate = HelperListener()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
