import Foundation

@main
struct ControlCommandRegression {
    static func main() {
        var gate = ControlCommandGate()
        let pendingStart = gate.begin()
        precondition(gate.isCurrent(pendingStart))
        let stop = gate.begin()
        precondition(!gate.isCurrent(pendingStart), "Delayed permission reply must not undo Pause")
        precondition(gate.isCurrent(stop))
        let newStart = gate.begin()
        precondition(!gate.isCurrent(stop))
        precondition(gate.isCurrent(newStart))
        let selectAnotherComputer = gate.begin()
        precondition(!gate.isCurrent(newStart), "An old command cannot affect a newly selected computer")
        precondition(gate.isCurrent(selectAnotherComputer))
        precondition(CodexModeError.chooseComputer.errorDescription != nil)
        precondition(gate.toggledTarget(current: false))
        let firstTap = gate.begin(pendingTarget: true)
        precondition(!gate.toggledTarget(current: false), "Second tap cancels a pending start")
        let secondTap = gate.begin()
        gate.finish(firstTap)
        precondition(gate.isCurrent(secondTap), "Old completion cannot overwrite the new command")
        precondition(gate.toggledTarget(current: false), "A third tap starts after pause")
        let thirdTap = gate.begin(pendingTarget: true)
        gate.finish(thirdTap)
        precondition(!gate.toggledTarget(current: true), "A completed start toggles to pause")
        print("PASS: delayed control commands lose to pause, restart, and computer selection.")
    }
}
