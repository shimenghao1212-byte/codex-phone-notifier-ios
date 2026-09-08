"""Read-only structural validation; this is not an iOS compiler or a BLE test."""
from pathlib import Path
import json
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def parse_openstep(text):
    pattern = r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,"]+'
    tokens = [m.group() for m in re.finditer(pattern, text, re.S)
              if not m.group().startswith(('/*', '//'))]
    position = 0

    def take(expected=None):
        nonlocal position
        value = tokens[position]
        position += 1
        if expected is not None:
            assert value == expected, (expected, value, position)
        return value

    def value():
        current = take()
        if current == '{':
            result = {}
            while tokens[position] != '}':
                key = take()
                if key.startswith('"'):
                    key = json.loads(key)
                take('=')
                assert key not in result, f'Duplicate key {key}'
                result[key] = value()
                take(';')
            take('}')
            return result
        if current == '(':
            result = []
            while tokens[position] != ')':
                result.append(value())
                if tokens[position] == ',':
                    take(',')
                else:
                    assert tokens[position] == ')'
            take(')')
            return result
        if current.startswith('"'):
            return json.loads(current)
        return current

    result = value()
    assert position == len(tokens), 'Unparsed project content'
    return result


project = parse_openstep((ROOT / 'CodexPhoneNotifier.xcodeproj/project.pbxproj').read_text(encoding='utf-8'))
objects = project['objects']
assert objects[project['rootObject']]['isa'] == 'PBXProject'


def verify_refs(node):
    if isinstance(node, dict):
        for val in node.values():
            verify_refs(val)
    elif isinstance(node, list):
        for val in node:
            verify_refs(val)
    elif re.fullmatch(r'[A-F0-9]{24}', node):
        assert node in objects, f'Missing Xcode reference {node}'


verify_refs(project)
file_paths = {}


def resolve_group(key, parent):
    obj = objects[key]
    if obj['isa'] == 'PBXGroup':
        folder = parent / obj.get('path', '')
        for child in obj['children']:
            resolve_group(child, folder)
    elif obj['isa'] == 'PBXFileReference' and obj.get('sourceTree') == '<group>':
        file_paths[key] = parent / obj['path']


resolve_group(objects[project['rootObject']]['mainGroup'], ROOT)
source_refs = {key: obj for key, obj in objects.items()
               if obj['isa'] == 'PBXFileReference' and obj.get('lastKnownFileType') == 'sourcecode.swift'}
for key in source_refs:
    assert file_paths[key].is_file(), file_paths[key]
targets = {obj['name']: obj for obj in objects.values() if obj['isa'] == 'PBXNativeTarget'}
assert set(targets) == {'CodexPhoneNotifier', 'CodexControls'}
compiled_by_target = {}
for name, target in targets.items():
    source_phase = next(objects[key] for key in target['buildPhases']
                        if objects[key]['isa'] == 'PBXSourcesBuildPhase')
    compiled = {objects[key]['fileRef'] for key in source_phase['files']}
    assert len(source_phase['files']) == len(compiled), f'Duplicate source in {name}'
    assert compiled <= set(source_refs)
    compiled_by_target[name] = {file_paths[key].relative_to(ROOT).as_posix() for key in compiled}
    resources = next(objects[key] for key in target['buildPhases']
                     if objects[key]['isa'] == 'PBXResourcesBuildPhase')
    resource_paths = {file_paths[objects[key]['fileRef']].relative_to(ROOT).as_posix()
                      for key in resources['files']}
    if name == 'CodexPhoneNotifier':
        assert 'CodexPhoneNotifier/Assets.xcassets' in resource_paths, 'Missing App icon'
    else:
        assert not resource_paths, 'Controls use system symbols; no image decoding or extra assets'
    configurations = objects[target['buildConfigurationList']]['buildConfigurations']
    for key in configurations:
        settings = objects[key]['buildSettings']
        assert settings['MARKETING_VERSION'] == '1.8.3'
        assert settings['CURRENT_PROJECT_VERSION'] == '14'
        assert settings['CODE_SIGN_ENTITLEMENTS'] == 'Shared/CodexControls.entitlements'
assert 'Shared/CodexActivityAttributes.swift' in compiled_by_target['CodexPhoneNotifier']
assert 'CodexPhoneNotifier/LiveActivityCoordinator.swift' in compiled_by_target['CodexPhoneNotifier']
assert 'CodexActivityWidget/CodexActivityWidget.swift' not in compiled_by_target['CodexPhoneNotifier']
assert 'CodexActivityWidget/CodexActivityViews.swift' not in compiled_by_target['CodexPhoneNotifier']
assert 'CodexPhoneNotifier/WidgetDesignPreviewScreen.swift' not in compiled_by_target['CodexPhoneNotifier']
all_compiled = set.union(*compiled_by_target.values())
assert all_compiled == {file_paths[key].relative_to(ROOT).as_posix() for key in source_refs}
assert len(targets['CodexPhoneNotifier']['dependencies']) == 1
assert not targets['CodexControls']['dependencies']
assert compiled_by_target['CodexControls'] == {'CodexControls/CodexControls.swift', 'Shared/CodexModeIntents.swift', 'Shared/CodexModeStore.swift'}
assert 'Shared/CodexModeIntents.swift' in compiled_by_target['CodexPhoneNotifier']
assert 'CodexPhoneNotifier/ControlCommandGate.swift' in compiled_by_target['CodexPhoneNotifier']
embed = [obj for obj in objects.values() if obj['isa'] == 'PBXCopyFilesBuildPhase']
assert len(embed) == 1 and embed[0]['dstSubfolderSpec'] == '13'
assert len(embed[0]['files']) == 1
product = objects[objects[embed[0]['files'][0]]['fileRef']]
assert product['path'] == 'CodexControls.appex'
for key in objects[targets['CodexControls']['buildConfigurationList']]['buildConfigurations']:
    settings = objects[key]['buildSettings']
    assert settings['APPLICATION_EXTENSION_API_ONLY'] == 'YES'
    assert 'CODEX_CONTROL_EXTENSION' in settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
    assert settings['IPHONEOS_DEPLOYMENT_TARGET'] == '18.0'
for obj in objects.values():
    if obj['isa'] == 'XCBuildConfiguration' and 'INFOPLIST_FILE' in obj['buildSettings']:
        assert (ROOT / obj['buildSettings']['INFOPLIST_FILE']).is_file()
    if obj['isa'] == 'XCBuildConfiguration' and 'IPHONEOS_DEPLOYMENT_TARGET' in obj['buildSettings']:
        assert obj['buildSettings']['IPHONEOS_DEPLOYMENT_TARGET'] in {'16.4', '18.0'}

with (ROOT / 'CodexPhoneNotifier/Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
assert set(info['UIBackgroundModes']) == {'bluetooth-central', 'audio', 'voip'}
assert info['NSBluetoothAlwaysUsageDescription']
assert info['NSAccessorySetupSupports'] == ['Bluetooth']
assert info['NSAccessorySetupBluetoothServices'] == ['5E2F4D60-A84C-4DB0-89ED-95A76E5AC901']
assert info['CFBundleDisplayName'] == 'Codex 提醒'
assert info['NSSupportsLiveActivities'] is True
assert 'NSAppTransportSecurity' not in info
for asset_name in ('CodexMark.imageset', 'AppIcon.appiconset'):
    folder = ROOT / 'CodexPhoneNotifier/Assets.xcassets' / asset_name
    catalog = json.loads((folder / 'Contents.json').read_text(encoding='utf-8'))
    for item in catalog['images']:
        if item.get('filename'):
            assert (folder / item['filename']).is_file()
scheme = ET.parse(ROOT / 'CodexPhoneNotifier.xcodeproj/xcshareddata/xcschemes/CodexPhoneNotifier.xcscheme')
for ref in scheme.findall('.//BuildableReference'):
    assert objects[ref.attrib['BlueprintIdentifier']]['isa'] == 'PBXNativeTarget'

receiver = (ROOT / 'CodexPhoneNotifier/BluetoothReceiver.swift').read_text(encoding='utf-8')
frame = (ROOT / 'CodexPhoneNotifier/EventFrame.swift').read_text(encoding='utf-8')
view = (ROOT / 'CodexPhoneNotifier/ContentView.swift').read_text(encoding='utf-8')
assert 'case abnormalPaused = 3' in frame, 'Missing wire kind 3'
assert 'case question = 4' in frame, 'Missing question reminder wire kind'
assert 'content.title =' in receiver and 'currentBrief?.heading ?? frame.kind.label' in receiver, 'Notification titles use batch heading with event-kind fallback'
assert 'Text(entry.kind.label)' in view, 'History must keep all event types distinct'
cleanup = (ROOT / 'CodexPhoneNotifier/LiveActivityCoordinator.swift').read_text(encoding='utf-8')
assert 'LegacyActivityCleanup' in cleanup
assert '.activities' in cleanup and '.end(' in cleanup, 'Old activities must still be terminable'
assert not re.search(r'\.\s*request\s*\(', cleanup), 'Cleanup must never create activities'
for ending in ['901', '902', '903']:
    assert f'5e2f4d60-a84c-4db0-89ed-95a76e5ac{ending}' in receiver
assert 'CBCentralManagerOptionRestoreIdentifierKey' in receiver
assert 'willRestoreState' in receiver
assert 'CodexPhoneNotifier/AccessoryAuthorization.swift' in compiled_by_target['CodexPhoneNotifier']
assert 'CodexPhoneNotifier/AccessorySetupCoordinator.swift' in compiled_by_target['CodexPhoneNotifier']
with (ROOT / 'CodexControls/Info.plist').open('rb') as handle:
    assert 'NSAccessorySetupSupports' not in plistlib.load(handle), 'Only the host owns accessory setup'
assert 'notifications.add(request)' in receiver
assert 'type: .withResponse' in receiver
assert 'suffix(128)' in receiver
assert '.banner' in receiver and '.list' in receiver and '.sound' in receiver
for source in [file_paths[key] for key in source_refs]:
    text = source.read_text(encoding='utf-8')
    assert '\ufffd' not in text, f'UTF-8 replacement character: {source}'
    assert not re.search(r'\b(URLSession|Network|WebKit)\b', text), f'Unexpected network framework: {source}'
    assert 'LiveActivityCoordinator.' not in text, f'Old activity creation path remains: {source}'
print(f'PASS: OpenStep project parsed; {len(objects)} objects and {len(source_refs)} Swift source paths resolve.')
print('PASS: App + one Controls extension, one shared App Group; version 1.8.3 (14).')
print('PASS: Plists, assets, shared scheme, BLE UUIDs, restoration flags, UTF-8 and local-only structure.')
print('NOT RUN: Swift compilation, EventFrameRegression, signing, installation, physical BLE / lock-screen tests.')

control = (ROOT / 'CodexControls/CodexControls.swift').read_text(encoding='utf-8')
intents = (ROOT / 'Shared/CodexModeIntents.swift').read_text(encoding='utf-8')
assert control.count('ControlWidgetToggle(') == 1, 'Exactly one persistent toggle'
assert 'ControlWidgetButton(' not in control
assert 'SetCodexModeIntent()' in control
assert 'CodexModeStore.live.read()' in control
with (ROOT / 'Shared/CodexControls.entitlements').open('rb') as handle:
    entitlements = plistlib.load(handle)
assert entitlements == {'com.apple.security.application-groups': ['group.local.codex.phone.notifier']}
assert 'ForegroundContinuableIntent' in intents and '#if !CODEX_CONTROL_EXTENSION' in intents
assert 'openAppWhenRun: Bool { false }' in intents
assert 'requireHost()' in intents, 'Wrong-process execution must not silently succeed'
with (ROOT / 'CodexControls/Info.plist').open('rb') as handle:
    extension_info = plistlib.load(handle)
assert extension_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
print('PASS: one persistent toggle; shared state; host-owned action; extension does not own BLE.')

for name in ('ReportWire.swift', 'ReportChannel.swift', 'VoiceReporter.swift', 'LatestReportView.swift'):
    assert 'CodexPhoneNotifier/' + name in compiled_by_target['CodexPhoneNotifier']
