import Foundation

let delegate = HelperXPCDelegate()
let listener = NSXPCListener(machServiceName: LittleCleanHelperConst.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
