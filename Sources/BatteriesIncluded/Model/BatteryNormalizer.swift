import Foundation

struct BatteryNormalizer: Sendable {
    func normalize(_ observations: [BatteryObservation], now: Date = .now) -> [DeviceBattery] {
        var grouped: [String: [BatteryObservation]] = [:]

        for observation in observations where observation.isConnected {
            let key = groupingKey(for: observation)
            grouped[key, default: []].append(observation)
        }

        mergeUniqueCrossSourceGroupsByName(&grouped)

        return grouped.values.map { observations in
            makeDevice(from: observations, now: now)
        }.sorted {
            let leftName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if leftName != .orderedSame {
                return leftName == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    private func groupingKey(for observation: BatteryObservation) -> String {
        if let stableID = observation.stableID {
            return "stable:\(stableID)"
        }
        return "\(observation.source.rawValue):\(observation.sourceID)"
    }

    private func mergeUniqueCrossSourceGroupsByName(
        _ grouped: inout [String: [BatteryObservation]]
    ) {
        var keysByName: [String: [String]] = [:]
        for (key, values) in grouped {
            guard let name = values.first(where: { !$0.name.isEmpty })?.name else { continue }
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedName.isEmpty else { continue }
            keysByName[normalizedName, default: []].append(key)
        }

        for keys in keysByName.values where keys.count == 2 {
            let sortedKeys = keys.sorted()
            guard let first = grouped[sortedKeys[0]],
                  let second = grouped[sortedKeys[1]] else { continue }

            let firstSources = Set(first.map(\.source))
            let secondSources = Set(second.map(\.source))
            let systemSources: Set<BatterySource> = [.system, .systemProfiler]

            if firstSources == [.logitechHID] || secondSources == [.logitechHID] {
                let logitechKey = firstSources == [.logitechHID] ? sortedKeys[0] : sortedKeys[1]
                let otherKey = logitechKey == sortedKeys[0] ? sortedKeys[1] : sortedKeys[0]
                let otherSources = Set(grouped[otherKey, default: []].map(\.source))
                guard otherSources.isSubset(of: systemSources.union([.coreBluetooth])) else { continue }
                grouped[otherKey, default: []].append(contentsOf: grouped.removeValue(forKey: logitechKey) ?? [])
                continue
            }

            let systemKey: String
            let bleKey: String
            if !firstSources.isDisjoint(with: systemSources), firstSources.contains(.coreBluetooth) == false,
               secondSources == [.coreBluetooth] {
                systemKey = sortedKeys[0]
                bleKey = sortedKeys[1]
            } else if !secondSources.isDisjoint(with: systemSources), secondSources.contains(.coreBluetooth) == false,
                      firstSources == [.coreBluetooth] {
                systemKey = sortedKeys[1]
                bleKey = sortedKeys[0]
            } else {
                continue
            }

            grouped[systemKey, default: []].append(contentsOf: grouped.removeValue(forKey: bleKey) ?? [])
        }
    }

    private func makeDevice(from observations: [BatteryObservation], now: Date) -> DeviceBattery {
        let newestFirst = observations.enumerated().sorted { left, right in
            if left.element.observedAt != right.element.observedAt {
                return left.element.observedAt > right.element.observedAt
            }
            return left.offset < right.offset
        }.map(\.element)

        let name = newestFirst.first(where: { !$0.name.isEmpty })?.name ?? "Unknown Device"
        let category = newestFirst.compactMap(\.category).first ?? .other

        var selected: [BatteryComponent: BatteryObservation] = [:]
        for observation in newestFirst where isValid(observation, now: now) {
            guard let existing = selected[observation.component] else {
                selected[observation.component] = observation
                continue
            }
            if isPreferred(observation, over: existing) {
                selected[observation.component] = observation
            }
        }

        if selected.keys.contains(where: { $0 != .whole }) {
            selected.removeValue(forKey: .whole)
        }

        let levels = selected.compactMap { component, observation in
            observation.percentage.map { (component: component, percentage: $0) }
        }
            .sorted { $0.component < $1.component }
        let coarseLevel = levels.isEmpty ? selected[.whole]?.coarseLevel : nil

        return DeviceBattery(
            id: normalizedID(for: observations[0]),
            name: name,
            category: category,
            levels: levels,
            coarseLevel: coarseLevel
        )
    }

    private func normalizedID(for observation: BatteryObservation) -> String {
        if let stableID = observation.stableID {
            return "stable:\(stableID)"
        }
        return "\(observation.source.rawValue):\(observation.sourceID)"
    }

    private func isValid(_ observation: BatteryObservation, now: Date) -> Bool {
        guard observation.percentage.map({ (0...100).contains($0) }) == true ||
              observation.coarseLevel != nil else {
            return false
        }
        let age = now.timeIntervalSince(observation.observedAt)
        return age <= 60
    }

    private func isPreferred(_ candidate: BatteryObservation, over existing: BatteryObservation) -> Bool {
        if (candidate.percentage != nil) != (existing.percentage != nil) {
            return candidate.percentage != nil
        }
        if candidate.source == .systemProfiler || existing.source == .systemProfiler {
            return candidate.source.rawValue > existing.source.rawValue
        }
        let difference = abs(candidate.observedAt.timeIntervalSince(existing.observedAt))
        if difference <= 1 {
            if candidate.source.rawValue != existing.source.rawValue {
                return candidate.source.rawValue > existing.source.rawValue
            }
        }
        return candidate.observedAt > existing.observedAt
    }
}
