import Foundation

class MockRenderQueue {
    var jobs: [String] = []
    var isRunning = false
    var runnerDrainedForTesting: (() -> Void)?
    var runnerTask: Task<Void, Never>?

    func enqueue(_ job: String) {
        jobs.append(job)
        start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        runnerTask = Task {
            await runLoop()
            runnerDidFinish()
        }
    }

    private func runLoop() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            print("running \(job)")
            await Task.yield()
        }
        runnerDrainedForTesting?()
    }

    private func runnerDidFinish() {
        runnerTask = nil
        isRunning = false
        if !jobs.isEmpty {
            start()
        }
    }
}

let q = MockRenderQueue()
var didInject = false
q.runnerDrainedForTesting = {
    guard !didInject else { return }
    didInject = true
    q.enqueue("B")
}
q.enqueue("A")

RunLoop.main.run(until: Date().addingTimeInterval(1))
