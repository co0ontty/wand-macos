import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

/// 群头像包含我和所有真实成员；每个格子使用同一个 ContactAvatar 规则。
struct ContactGroupAvatar: View {
    let profile: NativeUserProfile
    let members: [ConversationRecipient]
    let contacts: [EmployeeContact]
    var size: CGFloat = 44
    var body: some View {
        let columns = max(1, Int(ceil(sqrt(Double(members.count + 1)))))
        let cell = (size - CGFloat(columns - 1)) / CGFloat(columns)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 1), count: columns), spacing: 1) {
            ContactAvatar(id: "user", avatar: profile.avatar, name: profile.displayName, size: cell)
            ForEach(members, id: \.id) { member in
                let current = contacts.first { $0.id == member.employeeId }
                ContactAvatar(id: member.employeeId ?? member.id, avatar: current?.avatar ?? member.avatar ?? "", name: current?.name ?? member.name, size: cell)
            }
        }.frame(width: size, height: size).clipped().accessibilityHidden(true)
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




/// User and employee forms share preview, default seed, sculpt options and upload validation.
struct IdentityAvatarPicker: View {
    let id: String
    let name: String
    @Binding var avatar: String
    var disabled = false
    @State private var sculpting = false
    @State private var fields = ["round", "cream", "none", "none"]
    @State private var error: String?
    private let labels = ["造型", "颜色", "眼镜", "帽子"]
    private let options = [PlushAvatarIdentity.shapes, PlushAvatarIdentity.colors, PlushAvatarIdentity.glasses, PlushAvatarIdentity.hats]
    private let captions = [["心形", "圆角三角", "菱形", "圆形", "圆角方形", "胶囊"], ["珊瑚", "灰绿", "淡紫", "奶油", "雾蓝", "赭黄"], ["无眼镜", "金框眼镜", "黑框眼镜"], ["无帽子", "针织帽", "贝雷帽"]]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ContactAvatar(id: id, avatar: sculpting ? "plush:v1:" + fields.joined(separator: ":") : avatar, name: name, size: 56)
                Button("捏脸") {
                    let asset = PlushAvatarIdentity.asset(id: id, name: name, avatar: avatar) ?? "plush_round_cream_none_none"
                    let parts = asset.replacingOccurrences(of: "plush_", with: "").components(separatedBy: "_")
                    fields = parts.count == 4 ? parts : ["round", "cream", "none", "none"]
                    sculpting.toggle()
                }.buttonStyle(WandSecondaryButtonStyle())
                Button("上传图片", action: upload).buttonStyle(WandSecondaryButtonStyle())
                if !avatar.isEmpty { Button("恢复默认") { avatar = ""; sculpting = false }.buttonStyle(.plain) }
            }
            if sculpting {
                ForEach(0..<4, id: \.self) { index in
                    Picker(labels[index], selection: $fields[index]) {
                        ForEach(Array(options[index].enumerated()), id: \.offset) { item in Text(captions[index][item.offset]).tag(item.element) }
                    }.pickerStyle(.menu)
                }
                HStack {
                    Button("取消") { sculpting = false }.buttonStyle(WandSecondaryButtonStyle())
                    Button("使用这个头像") { avatar = "plush:v1:" + fields.joined(separator: ":"); sculpting = false }.buttonStyle(WandPrimaryButtonStyle())
                }.onExitCommand { sculpting = false }
            }
            Text("PNG、JPEG 或 WebP · 最大 10 MB；保存资料后生效。").font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            if let error { Text(error).font(.system(size: 12)).foregroundColor(Theme.danger) }
        }.disabled(disabled).wandMotion(value: sculpting, layout: true)
    }
    private func upload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 10 * 1024 * 1024, let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
                error = "请选择 10 MB 以内的有效图片。"; return
            }
            let side: CGFloat = 128
            let canvas = NSImage(size: NSSize(width: side, height: side))
            canvas.lockFocus()
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: side, height: side).fill()
            let scale = min(side / image.size.width, side / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            canvas.unlockFocus()
            guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { error = "图片处理失败。"; return }
            let value = "data:image/jpeg;base64," + jpeg.base64EncodedString()
            guard value.count <= 60_000 else { error = "头像太大，请换一张图片。"; return }
            avatar = value; sculpting = false; error = nil
        } catch { self.error = "图片读取失败，请重新选择。" }
    }
}
