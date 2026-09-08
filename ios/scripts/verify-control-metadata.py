"""Inspect actual Xcode output; directory presence alone cannot prove routing."""
import json
import sys
from pathlib import Path

app = Path(sys.argv[1])
bundles = [app, app / "PlugIns/CodexControls.appex"]
set_value = "com.apple.link.systemProtocol.SetValue"
foreground = "com.apple.link.systemProtocol.ForegroundContinuable"
for index, bundle in enumerate(bundles):
    metadata = json.loads((bundle / "Metadata.appintents/extract.actionsdata").read_text())
    action = metadata["actions"]["SetCodexModeIntent"]
    assert action["identifier"] == "SetCodexModeIntent"
    assert action["openAppWhenRun"] is False
    assert set_value in action["systemProtocols"]
    assert (foreground in action["systemProtocols"]) == (index == 0)
    parameters = action["parameters"]
    assert len(parameters) == 1 and parameters[0]["name"] == "value"
    assert parameters[0]["isOptional"] is False
    assert "ToggleCodexModeIntent" in metadata["actions"]
print("PASS: extracted host/extension SetValue intent identity, value parameter and background host routing.")
