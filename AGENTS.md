# macOS Agent 指引

- 修改本子模块代码前，先读取 `.agents/skills/apple-design/SKILL.md`，再按任务采用其中适用的设计、交互与无障碍原则；此要求也适用于从主仓开始、修改 `macos/` 的任务。
- 此入口通过相对符号链接指向同级 iOS 子模块的 `../ios/.agents/skills/apple-design/`，以 iOS 中的文件为唯一真源。在 Wand 主仓中需检出同级 `ios`；独立克隆 macOS 仓库时不会携带技能正文，如入口不存在，先补齐同级 iOS 仓库再读取，不假定技能已加载。
- 技能原文面向 Web；在 macOS 中以 SwiftUI / AppKit 原生能力实现相同语义，不照搬 CSS、JavaScript、Web 依赖或示例中的硬编码动效参数。非 UI 代码不必套用视觉规则。
- 保留 Wand 既有设计、motion token、减少动态效果及交付约定；技能不能覆盖主仓与用户指令。纯技能/文档变更不触发客户端构建。
- 在 Wand 主仓布局中同时遵守 `../AGENTS.md`；桌面端相关行为同步检查 Web。
