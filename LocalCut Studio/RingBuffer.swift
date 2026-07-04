import Foundation
import os

final class RingBuffer: @unchecked Sendable {
    private struct State {
        var buffer: [Float]
        var writePos: Int = 0
        var readPos: Int = 0
        var count: Int = 0
        let capacity: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    nonisolated init(capacity: Int) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(buffer: [Float](repeating: 0, count: capacity), capacity: capacity)
        )
    }

    nonisolated func write(_ samples: [Float]) {
        state.withLock { s in
            for sample in samples {
                s.buffer[s.writePos] = sample
                s.writePos = (s.writePos + 1) % s.capacity
                if s.count < s.capacity {
                    s.count += 1
                } else {
                    s.readPos = (s.readPos + 1) % s.capacity
                }
            }
        }
    }

    nonisolated func read(count requestedCount: Int) -> [Float] {
        state.withLock { s in
            let available = min(requestedCount, s.count)
            var result = [Float](repeating: 0, count: available)
            for i in 0..<available {
                result[i] = s.buffer[s.readPos]
                s.readPos = (s.readPos + 1) % s.capacity
            }
            s.count -= available
            return result
        }
    }
}
