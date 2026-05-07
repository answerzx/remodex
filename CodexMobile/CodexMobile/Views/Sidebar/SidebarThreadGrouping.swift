// FILE: SidebarThreadGrouping.swift
// Purpose: Produces sidebar thread groups from desktop project state and keeps archived chats separate.
// Layer: View Helper
// Exports: SidebarThreadGroupKind, SidebarThreadGroup, SidebarThreadGrouping

import Foundation

enum SidebarThreadGroupKind: Equatable {
    case pinned
    case conversations
    case project
    case archived
}

struct SidebarProjectChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let iconSystemName: String
    let projectPath: String
    let sortDate: Date
}

struct SidebarThreadGroup: Identifiable {
    let id: String
    let label: String
    let kind: SidebarThreadGroupKind
    let sortDate: Date
    let projectPath: String?
    let threads: [CodexThread]

    var iconSystemName: String {
        switch kind {
        case .pinned:
            return "pin"
        case .conversations:
            return "bubble.left"
        case .project:
            return CodexThread.projectIconSystemName(for: projectPath)
        case .archived:
            return "archivebox"
        }
    }

    func contains(_ thread: CodexThread) -> Bool {
        threads.contains(where: { $0.id == thread.id })
    }
}

enum SidebarThreadGrouping {
    static func makeGroups(
        from threads: [CodexThread],
        pinnedThreadIDs: [String] = [],
        desktopProjectState: CodexDesktopProjectState? = nil,
        now _: Date = Date(),
        calendar _: Calendar = .current
    ) -> [SidebarThreadGroup] {
        var groups: [SidebarThreadGroup] = []
        var archivedThreads: [CodexThread] = []
        let pinnedThreads = collectPinnedThreads(from: threads, pinnedRootThreadIDs: pinnedThreadIDs)
        let pinnedThreadIDSet = Set(pinnedThreads.map(\.id))

        for thread in threads {
            if thread.syncState == .archivedLocal {
                archivedThreads.append(thread)
            }
        }

        if let firstPinned = pinnedThreads.first {
            groups.append(
                SidebarThreadGroup(
                    id: "pinned",
                    label: "Pinned",
                    kind: .pinned,
                    sortDate: firstPinned.updatedAt ?? firstPinned.createdAt ?? .distantPast,
                    projectPath: nil,
                    threads: pinnedThreads
                )
            )
        }

        groups.append(contentsOf: makeLiveGroups(
            from: threads,
            excludingPinnedThreadIDs: pinnedThreadIDSet,
            desktopProjectState: desktopProjectState
        ))

        let sortedArchived = sortThreadsByRecentActivity(archivedThreads)
        if let firstArchived = sortedArchived.first {
            groups.append(
                SidebarThreadGroup(
                    id: "archived",
                    label: "Archived (\(sortedArchived.count))",
                    kind: .archived,
                    sortDate: firstArchived.updatedAt ?? firstArchived.createdAt ?? .distantPast,
                    projectPath: nil,
                    threads: sortedArchived
                )
            )
        }

        return groups
    }

    // Reuses the sidebar project grouping rules for places like the New Chat chooser.
    static func makeProjectChoices(
        from threads: [CodexThread],
        desktopProjectState: CodexDesktopProjectState? = nil
    ) -> [SidebarProjectChoice] {
        makeProjectGroups(from: threads, desktopProjectState: desktopProjectState).compactMap { group in
            guard let projectPath = group.projectPath else {
                return nil
            }

            return SidebarProjectChoice(
                id: group.id,
                label: group.label,
                iconSystemName: group.iconSystemName,
                projectPath: projectPath,
                sortDate: group.sortDate
            )
        }
    }

    // Resolves all live thread ids that belong to the tapped project, even if the visible group is filtered.
    static func liveThreadIDsForProjectGroup(
        _ group: SidebarThreadGroup,
        in threads: [CodexThread],
        desktopProjectState: CodexDesktopProjectState? = nil
    ) -> [String] {
        guard group.kind == .project else {
            return []
        }

        return sortThreadsByRecentActivity(
            threads.filter { thread in
                thread.syncState != .archivedLocal
                    && projectGroupID(for: thread) == group.id
                    && shouldGroupAsProject(thread, desktopProjectState: desktopProjectState)
            }
        ).map(\.id)
    }

    // Includes archived and pinned chats so local project removal fully hides the project on this device.
    static func allThreadIDsForProjectGroup(
        _ group: SidebarThreadGroup,
        in threads: [CodexThread],
        desktopProjectState: CodexDesktopProjectState? = nil
    ) -> [String] {
        guard group.kind == .project else {
            return []
        }

        return sortThreadsByRecentActivity(
            threads.filter { thread in
                projectGroupID(for: thread) == group.id
                    && shouldGroupAsProject(thread, desktopProjectState: desktopProjectState)
            }
        ).map(\.id)
    }

    private static func makeProjectGroup(projectKey: String, threads: [CodexThread]) -> SidebarThreadGroup {
        let sortedThreads = sortThreadsByRecentActivity(threads)
        let representativeThread = sortedThreads.first
        let sortDate = representativeThread?.updatedAt ?? representativeThread?.createdAt ?? .distantPast
        return SidebarThreadGroup(
            id: "project:\(projectKey)",
            label: representativeThread?.projectDisplayName ?? "Cloud",
            kind: .project,
            sortDate: sortDate,
            projectPath: representativeThread?.normalizedProjectPath,
            threads: sortedThreads
        )
    }

    // Keeps project-derived UI consistent by centralizing the live-thread → project bucket mapping.
    private static func makeLiveGroups(
        from threads: [CodexThread],
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String> = [],
        desktopProjectState: CodexDesktopProjectState? = nil
    ) -> [SidebarThreadGroup] {
        var conversationThreads: [CodexThread] = []
        var projectThreadsByProject: [String: [CodexThread]] = [:]

        for thread in threads where thread.syncState != .archivedLocal {
            guard !pinnedThreadIDs.contains(thread.id) else {
                continue
            }

            if shouldGroupAsProject(thread, desktopProjectState: desktopProjectState) {
                projectThreadsByProject[thread.projectKey, default: []].append(thread)
            } else {
                conversationThreads.append(thread)
            }
        }

        var groups = projectThreadsByProject.map { projectKey, projectThreads in
            makeProjectGroup(projectKey: projectKey, threads: projectThreads)
        }

        let sortedConversationThreads = sortThreadsByRecentActivity(conversationThreads)
        if let firstConversation = sortedConversationThreads.first {
            groups.append(
                SidebarThreadGroup(
                    id: "conversations",
                    label: "Conversations",
                    kind: .conversations,
                    sortDate: firstConversation.updatedAt ?? firstConversation.createdAt ?? .distantPast,
                    projectPath: nil,
                    threads: sortedConversationThreads
                )
            )
        }

        return groups.sorted { lhs, rhs in
            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }

            if lhs.kind != rhs.kind {
                return lhs.kind.sortRank < rhs.kind.sortRank
            }

            if lhs.label != rhs.label {
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }

            return lhs.id < rhs.id
        }
    }

    private static func makeProjectGroups(
        from threads: [CodexThread],
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String> = [],
        desktopProjectState: CodexDesktopProjectState? = nil
    ) -> [SidebarThreadGroup] {
        var liveThreadsByProject: [String: [CodexThread]] = [:]

        for thread in threads where thread.syncState != .archivedLocal {
            guard !pinnedThreadIDs.contains(thread.id) else {
                continue
            }
            guard shouldGroupAsProject(thread, desktopProjectState: desktopProjectState) else {
                continue
            }
            liveThreadsByProject[thread.projectKey, default: []].append(thread)
        }

        return liveThreadsByProject.map { projectKey, projectThreads in
            makeProjectGroup(projectKey: projectKey, threads: projectThreads)
        }
        .sorted { lhs, rhs in
            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }

            if lhs.label != rhs.label {
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }

            return lhs.id < rhs.id
        }
    }

    // Keeps pinned roots and their descendants together so sidebar trees do not split across sections.
    private static func collectPinnedThreads(
        from threads: [CodexThread],
        pinnedRootThreadIDs: [String]
    ) -> [CodexThread] {
        let liveThreads = threads.filter { $0.syncState != .archivedLocal }
        let threadsByID = Dictionary(uniqueKeysWithValues: liveThreads.map { ($0.id, $0) })
        let childrenByParentID = liveThreads.reduce(into: [String: [CodexThread]]()) { partialResult, thread in
            guard let parentThreadID = thread.parentThreadId else {
                return
            }
            partialResult[parentThreadID, default: []].append(thread)
        }
        var pinnedThreads: [CodexThread] = []
        var visitedThreadIDs: Set<String> = []

        for rootThreadID in pinnedRootThreadIDs {
            guard let rootThread = threadsByID[rootThreadID] else {
                continue
            }

            appendPinnedSubtree(
                rootThread,
                childrenByParentID: childrenByParentID,
                into: &pinnedThreads,
                visitedThreadIDs: &visitedThreadIDs
            )
        }

        return pinnedThreads
    }

    private static func appendPinnedSubtree(
        _ thread: CodexThread,
        childrenByParentID: [String: [CodexThread]],
        into pinnedThreads: inout [CodexThread],
        visitedThreadIDs: inout Set<String>
    ) {
        guard visitedThreadIDs.insert(thread.id).inserted else {
            return
        }

        pinnedThreads.append(thread)

        for childThread in childrenByParentID[thread.id] ?? [] {
            appendPinnedSubtree(
                childThread,
                childrenByParentID: childrenByParentID,
                into: &pinnedThreads,
                visitedThreadIDs: &visitedThreadIDs
            )
        }
    }

    private static func sortThreadsByRecentActivity(_ threads: [CodexThread]) -> [CodexThread] {
        threads.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id < rhs.id
        }
    }

    private static func projectGroupID(for thread: CodexThread) -> String {
        "project:\(thread.projectKey)"
    }

    private static func shouldGroupAsProject(
        _ thread: CodexThread,
        desktopProjectState: CodexDesktopProjectState?
    ) -> Bool {
        guard thread.normalizedProjectPath != nil else {
            return false
        }

        guard let desktopProjectState, desktopProjectState.hasDesktopProjectMarkers else {
            return true
        }

        if desktopProjectState.marksThreadAsProjectless(thread.id) {
            return false
        }

        return thread.isManagedWorktreeProject
            || desktopProjectState.containsExplicitProjectRoot(thread.normalizedProjectPath)
    }
}

private extension SidebarThreadGroupKind {
    var sortRank: Int {
        switch self {
        case .conversations:
            return 0
        case .project:
            return 1
        case .pinned:
            return 2
        case .archived:
            return 3
        }
    }
}
