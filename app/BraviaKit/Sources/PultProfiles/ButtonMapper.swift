import Foundation

/// Button names -> app keys (import_flipper_irdb.py, "Key mapping").
enum ButtonMapper {
    struct Mapped {
        /// (key, command) in `KeyAliases.keyOrder` order.
        var keys: [(key: String, cmd: ProfileCommand)]
        /// Buttons that fill no key, in file order, without repeated codes.
        var extra: [Button]
        /// Extra buttons dropped because their code is already a key or an earlier extra button.
        var dropped: Int
    }

    /// `map_buttons`: buttons in file order -> keys, extra and the number of duplicates dropped.
    static func mapButtons(_ buttons: [Button], aliases: KeyAliases) -> Mapped {
        let norms = buttons.map { ProfileNames.normalizeName($0.name) }
        let present = Set(norms.map(PyKey.init))
        var letterAlias: [PyKey: [String]] = [:]
        for group in aliases.letterGroups where group.allSatisfy({ present.contains(PyKey($0.letter)) }) {
            for (letter, key) in group {
                letterAlias[PyKey(key), default: []].append(letter)
            }
        }

        // Dual-label buttons such as 'Blue_|_epg' also answer to each label, after every full-name match.
        let parts: [[String]] = buttons.map { button in
            guard button.name.unicodeScalars.contains("|") else { return [] }
            return Py.split(button.name, separator: "|").map(ProfileNames.normalizeName).filter { !$0.isEmpty }
        }

        var keys: [(key: String, cmd: ProfileCommand)] = []
        var used = Set<Int>()
        for key in aliases.keyOrder {
            let names = aliases.aliases(for: key) + (letterAlias[PyKey(key)] ?? [])
            var rank: [PyKey: Int] = [:]
            for (i, name) in names.enumerated() {
                rank[PyKey(name)] = i   // {n: i for ...}: the last index of a repeated name wins
            }
            var best: (score: Int, pos: Int)?
            for (pos, norm) in norms.enumerated() {
                var score = rank[PyKey(norm)]
                if score == nil {
                    score = parts[pos].compactMap { rank[PyKey($0)].map { names.count + $0 } }.min()
                }
                if let score, best == nil || (score, pos) < (best!.score, best!.pos) {
                    best = (score, pos)
                }
            }
            if let best {
                keys.append((key, buttons[best.pos].cmd))
                used.insert(best.pos)
            }
        }

        var seen = Set(keys.map { $0.cmd.canonical })
        var extra: [Button] = []
        var dropped = 0
        for (pos, button) in buttons.enumerated() where !used.contains(pos) {
            let c = button.cmd.canonical
            if seen.contains(c) {
                dropped += 1
                continue
            }
            seen.insert(c)
            extra.append(button)
        }
        return Mapped(keys: keys, extra: extra, dropped: dropped)
    }
}
