#!/usr/bin/env python3
"""Bounded, standalone XCTest runner; no Xcode build, app launch, API calls or model calls.

Compile the real model files. Four unrelated dependencies are copied verbatim from
named source seams to avoid linking the UI/network stores; no filter/DTO mocks.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True, timeout=10).strip())
frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
seams = [
    ("PtyTerminalStore.swift", "struct PtyTerminalSnapshot:", "\nenum PtyTerminalInput"),
    ("CommunicationsRepository.swift", "struct ConversationHistory:", "\n\nprotocol CommunicationsServing"),
    ("FocusComposer.swift", "func composerThinkingPreference(", "\nstruct ComposerSettingLabel"),
    ("DesktopCommands.swift", "enum DesktopGroupChatPresentation", "\n/// One catalog"),
]
with tempfile.TemporaryDirectory(prefix="wand-conversation-filters-") as directory:
    temp = Path(directory)
    dependencies = ["import Foundation"]
    for filename, start, end in seams:
        source = (root / "Wand" / filename).read_text()
        dependencies.append(source[source.index(start):source.index(end)])
    (temp / "Dependencies.swift").write_text("\n".join(dependencies))
    tests = root / "WandTests/ConversationListFiltersTests.swift"
    names = re.findall(r"    func (test\w+)\(", tests.read_text())
    (temp / "main.swift").write_text(
        "import XCTest\nimport Foundation\n"
        "let suite = ConversationListFiltersTests.defaultTestSuite\nsuite.run()\n"
        f"guard let run = suite.testRun, run.executionCount == {len(names)}, run.totalFailureCount == 0 else {{ exit(1) }}\n"
    )
    subprocess.run([
        "swiftc", "-D", "CONVERSATION_FILTER_STANDALONE",
        "-I", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib"),
        "-L", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib"),
        "-Xlinker", "-rpath", "-Xlinker", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib"),
        "-F", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
        *[str(root / "Wand" / name) for name in ["WorkspaceModels.swift", "WandModels.swift", "CommunicationsModels.swift"]],
        str(temp / "Dependencies.swift"), str(tests), str(temp / "main.swift"),
        "-o", str(temp / "conversation-filter-tests"),
    ], check=True, timeout=120)
    subprocess.run([str(temp / "conversation-filter-tests")], check=True, timeout=30)
