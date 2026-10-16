import Foundation

enum WorkPriority {
    // Reflect Swift's effective priority, including promotion when a user
    // awaits background work. A child process needs its own explicit QoS.
    static var processQualityOfService: QualityOfService {
        let priority = Task.currentPriority
        if priority >= .userInitiated { return .userInitiated }
        if priority >= .utility { return .utility }
        return .background
    }
}
