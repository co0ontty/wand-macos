import AppKit
import SwiftUI

/// Same identity grammar and portraits as iOS; lists remain native, static, and offline.
struct ContactAvatar: View {
    let id: String
    var avatar: String = ""
    var name: String = ""
    var provider: String? = nil
    var team = false
    var size: CGFloat = 44
    var body: some View {
        Group {
            if !team, let asset = PlushAvatarIdentity.asset(id: id, name: name, avatar: avatar) {
                Image(asset).resizable().scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.3).fill(Theme.surfaceSoft)
                    if let photo { Image(nsImage: photo).resizable().scaledToFill() }
                    else if team {
                        Image(systemName: "person.3.fill").font(.system(size: size * 0.5, weight: .medium)).foregroundColor(Theme.info)
                    } else if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Image("WandLogo").resizable().scaledToFit().padding(size * 0.16)
                    } else {
                        Canvas { context, bounds in
                            let pixels = ContactCatAvatar.grid(coat: ContactCatAvatar.coatIndex(id: id, avatar: avatar))
                            let cell = bounds.width / 10
                            for (row, cells) in pixels.enumerated() {
                                for (column, rgb) in cells.enumerated() {
                                    guard let rgb else { continue }
                                    let color = Color(red: Double((rgb >> 16) & 255) / 255,
                                        green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
                                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(color))
                                }
                            }
                        }.frame(width: size * 0.74, height: size * 0.74)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: size * 0.3))
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if !team, let provider = WandProvider.normalizedID(provider) {
                let badge = min(20, max(13, size * 0.5))
                BrandLogo(provider: provider).frame(width: badge * 0.65, height: badge * 0.65)
                    .frame(width: badge, height: badge).background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: badge * 0.35))
                    .overlay(RoundedRectangle(cornerRadius: badge * 0.35).stroke(Theme.background, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }.accessibilityHidden(true)
    }
    private var photo: NSImage? {
        guard avatar.hasPrefix("data:image/"), avatar.utf8.count <= 2_000_000,
              let comma = avatar.firstIndex(of: ","), let bytes = Data(base64Encoded: String(avatar[avatar.index(after: comma)...])) else { return nil }
        return NSImage(data: bytes)
    }
}

// Mirrors the iOS/Web contract. No persistence and no rendering-name heuristics.
enum PlushAvatarIdentity {
    static let shapes = ["heart", "triangle", "diamond", "round", "square", "capsule"]
    static let colors = ["coral", "sage", "lavender", "cream", "blue", "ochre"]
    static let glasses = ["none", "gold", "ink"]
    static let hats = ["none", "beanie", "beret"]
    private static func hash(_ seed: String) -> UInt32 {
        var value: UInt32 = 0x811c9dc5
        for unit in seed.utf16 { value = (value ^ UInt32(unit)) &* 0x01000193 }
        value = (value ^ (value >> 16)) &* 0x85ebca6b
        value = (value ^ (value >> 13)) &* 0xc2b2ae35
        return value ^ (value >> 16)
    }
    static func fixedAsset(id: String) -> String? {
        switch id { case "e_wand_default": return "plush_cat_silver"; case "e_wand_ops": return "plush_cat_orange"; default: return nil }
    }
    static func asset(id: String, name: String = "", avatar: String) -> String? {
        if let fixed = fixedAsset(id: id) { return fixed }
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !avatar.hasPrefix("data:image/") { return nil }
        if avatar.hasPrefix("data:image/") || avatar.range(of: "^cat:[0-9]+$", options: .regularExpression) != nil { return nil }
        if avatar == "plush-dog:v1:shiba:red-scarf" { return "plush_dog_shiba_red" }
        if avatar == "plush-cat:v1:silver" { return "plush_cat_silver" }
        if avatar == "plush-cat:v1:orange" { return "plush_cat_orange" }
        let fields = avatar.components(separatedBy: ":")
        let options = [shapes, colors, glasses, hats]
        if fields.count == 6, fields[0] == "plush", fields[1] == "v1",
           options.indices.allSatisfy({ options[$0].contains(fields[$0 + 2]) }) {
            return "plush_" + fields.dropFirst(2).joined(separator: "_")
        }
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = !trimmedID.isEmpty ? trimmedID : !trimmedName.isEmpty ? trimmedName : "member"
        let keys = ["shape", "color", "glasses", "hat"]
        return "plush_" + options.enumerated().map { index, choices in
            choices[Int(hash("plush:v1:\(identity):\(keys[index])") % UInt32(choices.count))]
        }.joined(separator: "_")
    }
}


enum ContactCatAvatar {
    static let rows = ["TdTTTTTTdT", "dbdTTTTdbd", "dbbbbbbbbd", "bbwkbbwkbb", "bbwwbbwwbb",
        "bbbbppbbbb", "bdblbblbdb", "TbbbbbbbbT", "TTbdbbdbTT", "TTTbTTbTTT"]
    static let coats: [(base: Int, dark: Int, light: Int, eye: Int)] = [
        (0xF0923A, 0xC46A1A, 0xF0923A, 0x2D2D2D),
        (0x9EAAB8, 0x6B7B8D, 0xC5CED8, 0x3F8F55),
        (0xF4F1EA, 0x2F2F33, 0xF4F1EA, 0x2D2D2D),
        (0x3A3A40, 0x1E1E22, 0x55555C, 0xE9C63F),
        (0xE9DCC4, 0x6B4A36, 0xF4ECDD, 0x3F7FD8),
        (0x7C8BA6, 0x56627A, 0x98A6BE, 0xE0A43A),
        (0xF2E6D4, 0xC46A1A, 0x3A3A40, 0x2D2D2D),
        (0xF2B8C6, 0xC9788D, 0xF8D3DC, 0x2D2D2D)
    ]
    static func coatIndex(id: String, avatar: String) -> Int {
        if avatar.range(of: "^cat:[0-9]+$", options: .regularExpression) != nil,
           let explicit = Int32(avatar.dropFirst(4)) { return Int(explicit) % coats.count }
        var hash: Int32 = 0
        let seed = id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "member" : id
        for unit in seed.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return Int(abs(Int64(hash)) % Int64(coats.count))
    }
    static func grid(coat: Int) -> [[Int?]] {
        let palette = coats[((coat % coats.count) + coats.count) % coats.count]
        return rows.map { row in row.map { cell in
            switch cell {
            case "T": return nil
            case "b": return palette.base
            case "d": return palette.dark
            case "l": return palette.light
            case "w": return 0xFFFFFF
            case "k": return palette.eye
            default: return 0xF28B9A
            }
        } }
    }
}


