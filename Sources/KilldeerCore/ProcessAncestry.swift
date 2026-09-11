import Foundation

/// Walks parent links to answer "which process is this one really part of".
///
/// Both the orphan-helper check and the Chrome instance grouping need the same
/// walk, and both need it to fail the same way: a helper whose chain is broken
/// has to be distinguishable from one that simply belongs to something else.
public enum ProcessAncestry {
    /// Guards against a parent chain that never terminates. A reparented tree
    /// can point back into itself, and the walk has to stop rather than spin.
    private static let maximumDepth = 32

    /// The nearest ancestor satisfying `predicate`, or nil when the chain ends,
    /// loops, or runs longer than `maximumDepth` without a match.
    ///
    /// nil means "the parent chain does not reach one", which is not the same
    /// as "orphaned": a process that double-forks lands on launchd by design
    /// while its owner is still running. Callers that treat nil as an orphan
    /// have to rule those out first.
    public static func nearestAncestor(
        of process: ProcessSnapshot,
        byPID: [pid_t: ProcessSnapshot],
        matching predicate: (ProcessSnapshot) -> Bool
    ) -> ProcessSnapshot? {
        var visited: Set<pid_t> = [process.identity.pid]
        var parent = process.parentPID
        for _ in 0..<maximumDepth {
            guard parent > 1, !visited.contains(parent), let ancestor = byPID[parent] else { return nil }
            if predicate(ancestor) { return ancestor }
            visited.insert(parent)
            parent = ancestor.parentPID
        }
        return nil
    }
}
