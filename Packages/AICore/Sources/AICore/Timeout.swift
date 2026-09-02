import Foundation

/// 只允许被兑现一次的闭锁。用于让两个竞争的任务中只有一个能 resume continuation。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// 一次性置位的线程安全标志。用于「首片是否已到达」这类跨任务判断。
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// 给一段异步操作加硬超时。
///
/// **为什么不用 `withThrowingTaskGroup`**：TaskGroup 在退出时会隐式等待所有子任务结束。
/// 如果被包裹的操作**不响应取消**（端侧模型不可用时的 `respond()` 就是这样，实测挂死
/// 300s 不返回、不抛错），group 的收尾会一直阻塞，超时形同虚设。
///
/// 这里用两个非结构化任务竞速 + 一次性闭锁，保证调用方一定能在 `duration` 内拿到结果或
/// `ModelError.timedOut`。
///
/// **代价要说清楚**：超时后那个挂死的任务会泄漏，直到它自己结束或进程退出。这是有意接受的
/// —— 泄漏一个任务，好过整个 UI 永久卡住。
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeOnce()

    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            do {
                let value = try await operation()
                if gate.claim() { continuation.resume(returning: value) }
            } catch {
                if gate.claim() { continuation.resume(throwing: error) }
            }
        }

        Task {
            do {
                try await Task.sleep(for: duration)
            } catch {
                return // 计时任务本身被取消，说明操作已先完成
            }
            if gate.claim() {
                work.cancel()
                continuation.resume(throwing: ModelError.timedOut(duration))
            }
        }
    }
}
