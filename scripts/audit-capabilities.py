#!/usr/bin/env python3
"""Audit a frozen-source capability ledger; --write regenerates it, keeping recorded results.

Only the Python standard library is required. No build, GPU, download or tracker
mutation occurs. Extraction deliberately includes implementation-support symbols
as well as product controls, so helper declarations are never called user features.
"""
import argparse
import bisect
import collections
import hashlib
import json
import re
import subprocess
import catalog_source
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
JSON_PATH = ROOT / 'docs/CAPABILITY_INVENTORY.json'
MD_PATH = ROOT / 'docs/CAPABILITY_INVENTORY.md'
PINS = {'Compositor': '11d8d7a50992b24fd9a760a1c13b1c01b70aaf30',
        'PhotoCatalog': 'f4f8d3f12acc77fe5632720702c52a7cfefb5b58'}
SUFFIXES = {'.swift', '.rs', '.c', '.h', '.cpp', '.metal', '.ts', '.tsx'}
SOURCE_ROOTS = {'Compositor': ('Compositor', 'CompositorTests', 'CompositorUITests', 'CompositorQuickLook'),
                'PhotoCatalog': ('src', 'native', 'desktop/src', 'desktop/src-tauri/src', 'tests', 'examples')}
# Preserve newlines/offsets while hiding braces in strings and comments.
LEX = re.compile(r'/\*[\s\S]*?\*/|//[^\n]*|r(?P<hash>\#+)?"[\s\S]*?"(?P=hash)|"(?:\\.|[^"\\])*"')
TYPE = re.compile(r'\b(enum|struct|class|actor|extension|impl|trait|interface)\s+(?:<[^\n{}]*>\s*)?([A-Za-z_][\w.]*)[^\n{};]*\{')

def digest(data):
    return hashlib.sha256(data).hexdigest()

def mask(text):
    return LEX.sub(lambda m: ''.join('\n' if c == '\n' else ' ' for c in m.group()), text)

def baseline_root(name):
    return ROOT / ('engines/catalog' if name == 'PhotoCatalog' else 'vendor/' + name)

def paths():
    result = []
    for baseline, roots in SOURCE_ROOTS.items():
        for folder in roots:
            start = baseline_root(baseline) / folder
            if start.is_file(): result.append(start)
            elif start.exists():
                result.extend(p for p in start.rglob('*') if p.is_file() and p.suffix in SUFFIXES)
    result.extend(ROOT / 'engines/catalog' / p for p in ('build.rs', 'desktop/vite.config.ts', 'desktop/src-tauri/build.rs'))
    return sorted(set(result))

def is_test(path):
    s = str(path).lower()
    return '/tests/' in s or 'tests.swift' in s or '/compositortests/' in s or '/compositoruitests/' in s or bool(re.search(r'(?:_tests|\.test)\.', s))

# Declarations that sit in a layer-panel or session file but belong to another story's behavior. Keyed by file
# name and exact symbol; these take precedence over the path and symbol-token rules in story_for.
SYMBOL_STORIES = {
    # Transform, distort previews, snapping and the viewport (S12).
    'sc-24667': {'LayerMask.swift': ('MaskDistortPreviewCache.corners', 'MaskDistortPreviewCache.draft', 'MaskDistortPreviewCache.mask',
                                     'MaskDistortPreviewCache.layer', 'MaskDistortPreviewCache.result', 'EditorSession.maskDistortPreview'),
                 'EditorSession.swift': ('EditorSession.distortPreviewCache', 'EditorSession.maskDistortPreviewCache', 'EditorSession.viewport', 'EditorSession.fit'),
                 'CompositorApp.swift': ('Toggle:Layers',),
                 'ContentView.swift': ('Button:Fit', 'Button:100%')},
    # Painting on a mask (S14).
    'sc-24669': {'LayerMask.swift': ('BrushStroke.placedMaskPreview',)},
    # Selections (S13).
    'sc-24668': {'EditorSession.swift': ('EditorSession.marqueeKind', 'EditorSession.pixelMove')},
    # Adjustments and layer effects (S11).
    'sc-24666': {'EditorSession.swift': ('EditorSession.hueTargeting', 'EditorSession.hueTargetDrag'),
                 'NativeLayerList.swift': ('Coordinator.effectType',)},
    # Type (S16).
    'sc-24671': {'EditorSession.swift': ('EditorSession.fontPreviewOriginal',)},
    # Photoshop import and opening documents (S20).
    'sc-24675': {'EditorSession.swift': ('EditorSession.conversionRequest', 'EditorSession.confirmConversions', 'EditorSession.beginPSDReading',
                                         'EditorSession.finishPSDReading', 'EditorSession.endPSDReading', 'EditorSession.confirmPSDConversions',
                                         'EditorSession.finishConversion', 'EditorSession.insertPhotoshop'),
                 'CompositorApplicationDelegate.swift': ('CompositorApplicationDelegate.workspace', 'CompositorApplicationDelegate.showEditor',
                                                         'CompositorApplicationDelegate.application', 'CompositorApplicationDelegate.applicationWillFinishLaunching',
                                                         'CompositorApplicationDelegate.applicationDidFinishLaunching', 'CompositorApplicationDelegate.applicationShouldTerminate')},
    # RAW develop (S08).
    'sc-24663': {'EditorSession.swift': ('EditorSession.rawDevelop', 'EditorSession.confirmRawDevelop', 'EditorSession.developRaw', 'EditorSession.finishRawDevelop')},
    # Tools, keyboard, palette and window chrome (S34).
    'sc-24689': {'NativeLayerList.swift': ('LayerTableView.keyDown',),
                 'EditorSession.swift': ('EditorSession.tool', 'EditorSession.symbol', 'EditorSession.cycleToolMode', 'EditorSession.next',
                                         'EditorSession.busyIndicatorDelay', 'EditorSession.waitForFileRequest'),
                 'ToolDefaults.swift': ('ToolDefaults.bool', 'ToolDefaults.set', 'ToolDefaults.int', 'ToolDefaults.string'),
                 'ColorPalette.swift': ('EditorSession.channel', 'PickerHSB.hue', 'PickerHSB.brightness', 'PickerHSB.setRGB'),
                 'ContentView.swift': ('ContentView.session', 'ContentView.applicationDelegate', 'Button:OK', 'View.roundedControls',
                                       'View.releasesFocusOnCommit', 'ArrowStepper.editing', 'ArrowStepper.listen', 'ArrowStepper.stopListening', 'View.arrowSteps')},
}
SYMBOL_STORY = {(name, symbol): story for story, files in SYMBOL_STORIES.items() for name, symbols in files.items() for symbol in symbols}

def story_for(path, symbol=''):
    """Map individual source rows; primary owner plus integration terminal review."""
    if path.startswith('vendor/Compositor/Compositor/') and (Path(path).name, symbol) in SYMBOL_STORY:
        return SYMBOL_STORY[(Path(path).name, symbol)]
    p = path.lower()
    s = symbol.lower()
    if 'photocatalog' in p or 'engines/catalog/' in p:
        if any(x in p for x in ('lightroom', 'migration')): return 'sc-24662'
        if 'backup' in p: return 'sc-24677'
        if any(x in p for x in ('relink', 'storage_volume', 'catalog_storage')): return 'sc-24661'
        if any(x in p for x in ('metadata', 'organization', '/xmp')): return 'sc-24660'
        if any(x in p for x in ('export', 'image_export')): return 'sc-24676'
        if any(x in p for x in ('recipe', '/edit/', 'photo_render', '/media/')): return 'sc-24663'
        if any(x in p for x in ('/preview/', 'previewsettings', 'import', 'photogrid', 'foldertree', 'catalogactivity')): return 'sc-24659'
        if any(x in p for x in ('filesystem', '/worker', 'transport', 'bridge', 'session', '/lib.rs', 'application')): return 'sc-24658'
        if any(x in p for x in ('performance', 'measurement', 'probe')): return 'sc-24694'
        if '/desktop/' in p: return 'sc-24689'
        return 'sc-24658'
    if s.startswith('navigationtool.'):
        tool = s.split('.')[-1]
        return {'move': 'sc-24667', 'marquee': 'sc-24668', 'lasso': 'sc-24668',
                'wand': 'sc-24668', 'crop': 'sc-24667', 'brush': 'sc-24669',
                'spothealing': 'sc-24670', 'clonestamp': 'sc-24670', 'blur': 'sc-24669',
                'gradient': 'sc-24671', 'shape': 'sc-24671', 'type': 'sc-24671',
                'eyedropper': 'sc-24669', 'hand': 'sc-24667', 'zoom': 'sc-24667',
                'idle': 'sc-24689'}.get(tool, 'sc-24689')
    if any(x in p for x in ('keyboard', 'floatingpanel', 'projecttab', 'windowbridge', 'heldmodifiers', 'titlesbar', 'indicatorless')): return 'sc-24689'
    if any(x in p for x in ('projectwatcher', 'externalchange')): return 'sc-24674'
    if any(x in p for x in ('projectstore', 'projectdigest', 'documenthistory', 'projectworkspace')): return 'sc-24672'
    if 'imageexporter' in p or 'jpegexport' in p: return 'sc-24676'
    if '/io/psd/' in p or 'conversion' in p: return 'sc-24675'
    if 'rawimporter' in p or 'rawdevelopsheet' in p: return 'sc-24663'
    if any(x in p for x in ('clone', 'healpixels', 'spothealing')): return 'sc-24670'
    if any(x in p for x in ('brush', 'blurtool', 'smudge', 'liquify')): return 'sc-24669'
    if any(x in p for x in ('shapetool', 'shapecontrols', 'typetool', 'typecontrols', 'texteditor', 'gradient.swift', 'gradientcontrols')): return 'sc-24671'
    if any(x in p for x in ('selection', 'wand', 'lasso', 'contentfill', 'color range', 'colorrange', 'guidedmatte', 'subjectremoval', 'objectselection')): return 'sc-24668'
    if any(x in p for x in ('crop', 'transform', 'distort', 'canvassize', 'canvasresizer', 'imagesize', 'imageresizer', 'imagetrim', 'trimsheet', 'guide', 'ruler', 'gridsettings', 'viewport')): return 'sc-24667'
    if any(x in p for x in ('adjust', 'effects', 'filter', 'cameraraw', 'curves', 'levels', 'hue', 'dither', 'pixelinvert', 'pixeladjust', 'lens', 'noise')): return 'sc-24666'
    if '/rendering/' in p:
        # Canvas event handlers belong to the exercised tool/input behavior;
        # renderer plumbing still belongs to precision/tile adaptation.
        if any(x in s for x in ('keydown', 'keyup', 'modifier', 'gesture', 'tablet', 'pressure', 'scrollwheel')): return 'sc-24689'
        if any(x in s for x in ('heal', 'clone')): return 'sc-24670'
        if any(x in s for x in ('brush', 'paint', 'smudge', 'warp', 'blur')): return 'sc-24669'
        if any(x in s for x in ('select', 'wand', 'lasso', 'marquee')): return 'sc-24668'
        if any(x in s for x in ('shape', 'text', 'gradient')): return 'sc-24671'
        if any(x in s for x in ('crop', 'transform', 'zoom', 'pan', 'guide', 'snap')): return 'sc-24667'
        return 'sc-24664'
    if any(x in p for x in ('layermask', 'livelayermask', 'masktracing', 'layermerge', 'layergroup', 'layerflip', 'layerappearance', 'layerspanel', 'layerlist', 'blendmode')): return 'sc-24665'
    # Shared session/menu/controller dispatch needs per-symbol ownership.
    if any(x in s for x in ('export', 'jpeg', 'png')): return 'sc-24676'
    if any(x in s for x in ('updat', 'sparkle')): return 'sc-24690'
    if any(x in s for x in ('undo', 'redo', 'history', 'save')): return 'sc-24672'
    if any(x in s for x in ('select', 'wand', 'lasso', 'fill', 'clipboard', 'copy', 'paste', 'cut')): return 'sc-24668'
    if any(x in s for x in ('brush', 'eras', 'blur', 'smear')): return 'sc-24669'
    if any(x in s for x in ('clone', 'heal')): return 'sc-24670'
    if any(x in s for x in ('shape', 'text', 'gradient', 'type tool')): return 'sc-24671'
    if any(x in s for x in ('filter', 'effect', 'adjustment', 'curves', 'levels', 'saturation', 'invert')): return 'sc-24666'
    if any(x in s for x in ('zoom', 'canvas', 'crop', 'snap', 'grid', 'guide', 'ruler', 'transform', 'nudge', 'trim')): return 'sc-24667'
    if any(x in s for x in ('project', 'import', 'open', 'document')): return 'sc-24675'
    if any(x in s for x in ('layer', 'group', 'mask', 'blend')): return 'sc-24665'
    if any(x in s for x in ('color', 'eyedropper', 'palette', 'sample')): return 'sc-24669'
    if '/ui/' in p or 'app.swift' in p: return 'sc-24689'
    return 'sc-24665'

def extract(path):
    original = path.read_text(errors='replace')
    clean = mask(original)
    starts = [0] + [m.end() for m in re.finditer('\n', original)]
    # Depth independent of declaration matching prevents switch cases/local vars
    # becoming enum variants/configuration fields.
    depth = [0] * (len(clean) + 1)
    stack, pairs = [], {}
    for i, c in enumerate(clean):
        depth[i] = len(stack)
        if c == '{': stack.append(i)
        elif c == '}' and stack: pairs[stack.pop()] = i
    types = []
    for m in TYPE.finditer(clean):
        opening = m.end() - 1
        if opening in pairs: types.append((opening, pairs[opening], m.group(1), m.group(2)))
    types.sort()
    rows = []
    seen = set()
    def owner(pos):
        candidates = [t for t in types if t[0] < pos < t[1]]
        return max(candidates, default=None, key=lambda t: t[0])
    def add(pos, kind, symbol, excerpt=None):
        line = bisect.bisect_right(starts, pos)
        key = (line, kind, symbol)
        if key in seen: return
        seen.add(key)
        if excerpt is None:
            excerpt = original[starts[line - 1]:original.find('\n', starts[line - 1]) if '\n' in original[starts[line - 1]:] else len(original)].strip()
        t = owner(pos)
        visibility = 'internal'
        if path.suffix == '.rs':
            declaration_start = original.rfind('\n', 0, pos) + 1
            own_line = original[declaration_start:original.find('\n', pos) if '\n' in original[pos:] else len(original)]
            header = original[original.rfind('\n', 0, t[0]) + 1:t[0]] if t else ''
            visibility = 'public' if re.search(r'\bpub\s+(?:fn|async|enum|struct|trait|const|static|\w+\s*:)', own_line + ' ' + header) else 'internal'
        elif path.suffix == '.swift':
            header = original[original.rfind('\n', 0, t[0]) + 1:t[0]] if t else ''
            visibility = 'private' if 'private' in header or 'private' in excerpt.split('func')[0] else 'internal'
        rows.append({'line': line, 'kind': kind, 'symbol': symbol, 'declaration': excerpt[:500], 'visibility': visibility})
    for begin, end, typ, name in types:
        add(begin, 'type', name)
        if typ == 'enum':
            if path.suffix == '.swift':
                for m in re.finditer(r'\bcase\s+([^\n};]+)', clean[begin + 1:end]):
                    pos = begin + 1 + m.start()
                    if depth[pos] != depth[begin] + 1: continue
                    # Split only commas outside associated-value parentheses.
                    chunk = original[begin + 1 + m.start():begin + 1 + m.end()]
                    chunk = re.sub(r'^case\s+', '', chunk)
                    for case in re.split(r',\s*(?![^()]*\))', chunk):
                        item = re.match(r'([A-Za-z_]\w*)', case.strip())
                        if item: add(pos, 'enum_case', name + '.' + item.group(1), case.strip())
            elif path.suffix == '.rs':
                for m in re.finditer(r'(?m)^\s*([A-Za-z_]\w*)\s*(?:[,=({])', clean[begin + 1:end]):
                    pos = begin + 1 + m.start(1)
                    if depth[pos] == depth[begin] + 1: add(pos, 'enum_case', name + '.' + m.group(1))
    if path.suffix in {'.swift', '.rs'}:
        pattern = r'\b(?:func|fn)\s+([A-Za-z_]\w*|==|!=|\+=|\+|-|\*)'
        for m in re.finditer(pattern, clean):
            t = owner(m.start())
            symbol = (t[3] + '.' if t else '') + m.group(1)
            line_start = original.rfind('\n', 0, m.start()) + 1
            prefix = clean[line_start:m.start()]
            public = path.suffix == '.rs' and bool(re.search(r'\bpub\s*(?:\([^)]*\))?', prefix))
            if path.suffix == '.rs' and t and t[2] == 'trait':
                header = original[original.rfind('\n', 0, t[0]) + 1:t[0]]
                public = public or bool(re.search(r'\bpub\s+trait\b', header))
            if m.group(1).startswith('test') and path.suffix == '.swift': kind = 'baseline_test'
            elif public: kind = 'rust_api'
            elif path.suffix == '.swift' and 'private' not in prefix: kind = 'swift_operation'
            else: kind = 'support_operation'
            add(m.start(), kind, symbol)
        if path.suffix == '.swift':
            for m in re.finditer(r'\b(init|deinit|subscript)\s*(?:\?\s*)?\(', clean):
                t = owner(m.start())
                if t and depth[m.start()] == depth[t[0]] + 1:
                    add(m.start(), 'support_operation', t[3] + '.' + m.group(1))
        else:
            for m in re.finditer(r'\bpub(?:\([^)]*\))?\s+(type|use|mod)\s+([^;{\n]+)', clean):
                add(m.start(), 'source_export', m.group(1) + ':' + m.group(2).strip())
        pattern = r'\b(?:var|let)\s+([A-Za-z_]\w*)' if path.suffix == '.swift' else r'\b(?:pub(?:\([^)]*\))?\s+)?([A-Za-z_]\w*)\s*:(?!:)'
        for m in re.finditer(pattern, clean):
            t = owner(m.start())
            if not t or depth[m.start()] != depth[t[0]] + 1: continue
            if t[2] not in {'enum', 'struct', 'class', 'actor', 'extension'}: continue
            add(m.start(), 'setting_or_field', t[3] + '.' + m.group(1))
        if path.suffix == '.rs':
            for begin, end, typ, name in types:
                if typ != 'enum': continue
                # Include named associated values (including inline payloads),
                # not only the enclosing operation/profile variant.
                variants = list(re.finditer(r'(?m)^\s*([A-Za-z_]\w*)\s*\{', clean[begin + 1:end]))
                for variant in variants:
                    pos = begin + 1 + variant.start(1)
                    opening = begin + variant.end()
                    if depth[pos] != depth[begin] + 1 or opening not in pairs: continue
                    for field in re.finditer(r'\b([A-Za-z_]\w*)\s*:(?!:)', clean[opening + 1:pairs[opening]]):
                        field_pos = opening + 1 + field.start()
                        if depth[field_pos] == depth[opening] + 1:
                            add(field_pos, 'variant_field', name + '.' + variant.group(1) + '.' + field.group(1))
            for m in re.finditer(r'\bpub(?:\([^)]*\))?\s+(?:const|static)\s+([A-Za-z_]\w*)', clean):
                t = owner(m.start())
                add(m.start(), 'rust_constant', (t[3] + '.' if t else '') + m.group(1))
    if path.suffix == '.swift':
        for m in re.finditer(r'\b(Button|Toggle|Picker|TextField|Slider|Stepper|ColorPicker|Menu|CameraRawSlider|NumericScrub)\s*\(\s*"((?:\\.|[^"\\])*)"', original):
            add(m.start(), 'ui_control', m.group(1) + ':' + m.group(2))
        for m in re.finditer(r'\bentry\(\s*"((?:\\.|[^"\\])*)"', original):
            add(m.start(), 'keyboard_command', m.group(1))
        # Native event path: keyboard/tablet/mouse/gesture entry points themselves
        # are extracted as operations. Every binding adds its own control target.
        for m in re.finditer(r'\$([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+)', original):
            add(m.start(), 'control_binding', m.group(1))
    elif path.suffix in {'.ts', '.tsx'}:
        for m in re.finditer(r'\bexport\s+(?:async\s+)?(?:function|const|type|interface|class|enum)\s+([A-Za-z_]\w*)', clean):
            add(m.start(), 'desktop_api', m.group(1))
        for m in re.finditer(r'\b(aria-label|title|placeholder|name)\s*=\s*"([^"\n]+)"', original):
            add(m.start(), 'ui_control', m.group(1) + ':' + m.group(2))
        for m in re.finditer(r'<(button|label|option)[^>]*>\s*([^<{\n]+)', original):
            add(m.start(), 'ui_control', m.group(1) + ':' + m.group(2).strip())
        for m in re.finditer(r'\b(onClick|onChange|onKeyDown|onDoubleClick|onContextMenu)\s*=\s*\{([^\n]+)', original):
            add(m.start(), 'input_binding', m.group(1) + ':' + m.group(2).strip()[:140])
        # All declared interface/type-object fields, including bridge request and
        # result DTO controls; values inside function blocks are not fields.
        for m in re.finditer(r'(?m)^\s*([A-Za-z_]\w*)\??\s*:\s*([^;\n]+)', clean):
            if depth[m.start(1)] == 1: add(m.start(1), 'desktop_field', m.group(1))
        for m in re.finditer(r'(?m)^\s*\|?\s*"([^"\n]+)"\s*(?:\||;|$)', original):
            add(m.start(), 'desktop_variant', m.group(1))
        for m in re.finditer(r'\btype\s+([A-Za-z_]\w*)\s*=\s*([^;]+);', original):
            if '{' not in m.group(2) and '|' in m.group(2):
                for choice in re.finditer(r'"([^"\n]+)"', m.group(2)):
                    add(m.start(2) + choice.start(), 'desktop_variant', m.group(1) + '.' + choice.group(1))
    elif path.suffix in {'.h', '.c', '.cpp', '.metal'}:
        for m in re.finditer(r'(?m)^\s*(?:(?:extern|static|inline|kernel)\s+)*(?:[\w:*<>]+\s+)+([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:;|\{)', clean):
            add(m.start(1), 'native_operation', m.group(1))
    return sorted(rows, key=lambda r: (r['line'], r['kind'], r['symbol']))

def fixture_assets():
    return {
        'rgba-four': {'construction': '4x1 encoded-sRGB RGBA8 pixels [[255,0,0,255],[0,255,0,255],[0,0,255,128],[0,0,0,0]]', 'purpose': 'exact color, straight/premultiplied alpha, selection and invert assertions'},
        'edge64': {'construction': '64x64 transparent RGBA image; opaque white square x/y in [16,48), one opaque black pixel at (32,32)', 'purpose': 'blur, geometry, matte, paint and effect spatial assertions'},
        'ramp256': {'construction': '256x1 RGBA image pixel(x)=[x,x,x,255] for x in 0...255; companion same-size opaque flat gray [128,128,128,255]', 'purpose': 'tone endpoints, monotonicity, identity, blur-flat-field assertions'},
        'hdr2': {'construction': '2x2 straight-alpha linear-sRGB f32 pixels [[-0.1,0.18,1.6,1],[0.5,0.25,0.125,0.5],[1,1,1,1],[0,0,0,0]]', 'purpose': 'LensWorks precision contract; no source-byte mutation or premature clamp'},
        'catalog-two': {'construction': 'Use engines/catalog/tests/catalog.rs setup/jpeg/synthetic_cr2 helpers: a.jpg 96x64 with B=3; b.CR2 miniature TIFF/JPEG container 48x32 EXIF orientation=6; source folder originals ü 日本語 outside catalog', 'purpose': 'two stable identities, CR2 preview orientation (32,48), repeat-import unchanged=2, offline cached preview; synthetic CR2 is not real RAW-camera evidence'},
        'layered3': {'construction': '64x64 document: bottom rgba-four expanded to canvas, middle edge64 raster layer with half-opacity reveal mask, top editable text LensWorks; one group; source-identity and source-byte hashes recorded', 'purpose': 'layer graph, export, undo, save/reopen, standalone/import conversion'},
        'lightroom-frozen': {'construction': 'Execute retained Lightroom/capture/plan/migration test builders listed by each referenced baseline test ID in an isolated directory; immutable source descriptors and approval snapshots included', 'purpose': 'source-backed full relationship, raw-payload, compatibility-report and interrupted migration assertions; do not invent undocumented Lightroom schema'},
        'real-raw': {'construction': 'Owner-selected real camera RAW fixture admitted by pinned decoder on target macOS, with file SHA-256, camera identity and embedded profile recorded before edit', 'purpose': 'additional real-camera gate; requires concrete camera fixture selection before passing status', 'unresolved': 'No single system-wide UTType/CIRAWFilter camera guarantee is possible from frozen source.'},
    }

def fixture_profiles():
    # These are executable scenario specifications to implement in each owning
    # story. They are not reports of tests that have already been run.
    p = {}
    def add(name, assets, action, expected, parameters=None):
        p[name] = {'asset_ids': assets, 'action': action, 'parameters': parameters or {},
                   'expected_observables': expected, 'status': 'planned'}
    add('catalog-service', ['catalog-two'], 'Open a new catalog; import source; browse with limit=1, then after=first.sequence; get both IDs; repeat import; reopen; rename original folder offline; request both previews.',
        ['imported=2 initially; unchanged=2 on repeat', 'two distinct IDs and increasing sequences; no third page', 'CR2 metadata width=48,height=32,orientation=6; preview dimensions=32x48', 'same IDs after reopen; previews work offline', 'browse limit=1001 and negative after reject without changing catalog'])
    add('catalog-adapter', ['catalog-two'], 'Invoke bound source operation with a live opaque catalog handle; serialize/round-trip its exact public request/result; cancel an active import; release returned buffers and handle; exercise invalid/released handle.',
        ['same typed fields and IDs as retained Rust result', 'cancelled work reports actual durable boundary and can resume without duplicate IDs', 'no Rust panic crosses Swift; invalid/released handle returns typed error; buffers have one owner', 'catalog-two source bytes unchanged'])
    add('metadata-organization', ['catalog-two'], 'Import; set rating=3, pick flag, blue label and hierarchical keyword People/Ada; create collection Portraits; add first ID; search/filter; reopen; undo metadata operation; round-trip XMP unknown-property fixture from retained tests.',
        ['first ID appears once in rating/pick/keyword/collection filters; second ID excluded', 'rating 3 and keyword hierarchy survive reopen', 'undo restores prior values; expected_revision mismatch rejects stale write', 'unknown XMP namespace/property and original packet retained; original photo byte hashes unchanged'])
    add('offline-relink', ['catalog-two'], 'Record both IDs and hashes; rename source folder offline; browse and preview; supply same bytes under a new folder; relink; then supply wrong bytes/ambiguous duplicates.',
        ['offline status visible; both cached previews still decode', 'verified relink restores availability with original IDs', 'wrong or ambiguous replacement produces review/error instead of silently changing source identity', 'catalog/preview paths remain separate from original media'])
    add('migration', ['lightroom-frozen'], 'Run source test builder with folders, keywords, collections, recipe and metadata conflicts; capture and seal approval; migrate into an empty catalog; interrupt at retained publication boundary; resume; mutate approval source and retry.',
        ['all source-backed expected counts and relationship assertions in referenced fixture hold', 'unsupported payload retained with compatibility report', 'resume produces no duplicate images/versions/relationships', 'changed source/approval is rejected; Lightroom/source catalog byte hashes unchanged'])
    add('raw-develop', ['hdr2', 'real-raw', 'layered3'], 'Decode full source; set exposure +1 EV and temperature 6500 K; paint an opaque red upper-layer stroke; change exposure to +2 EV; save/reopen; compare preview and full export.',
        ['working buffer preserves negative/highlight values and straight alpha before display/export conversion', 'developed source responds below unchanged editable stroke', 'source file SHA-256 identical before/after', 'recipe/layers survive reopen; full export evaluates live source rather than browse JPEG'], {'real_camera_gate': 'must select and qualify real-raw before marking passing'})
    add('precision-render', ['hdr2', 'layered3'], 'Render the same document in full and bounded tile paths; hide/show upper layers; evaluate alpha in zero and half-alpha samples; convert only at display boundary.',
        ['source float values remain unclamped upstream', 'full/tiled paths agree under approved numerical tolerance; no tile seams', 'zero-alpha sample has no visible hidden-RGB fringe', 'layer order and masks agree in native display and full-resolution export'], {'tolerance': 'must be approved in renderer story; no numerical support claim here'})
    add('layer-graph', ['layered3'], 'Duplicate the middle layer; move it into/out of group; rename; reorder; toggle visibility; set opacity=0.5; create clipping/reveal/hide masks; merge selected layers; undo; save/reopen.',
        ['layer UUIDs preserved except intentional duplicate; parent/order/visibility/opacity fields round-trip', 'hidden or fully masked adjustment/raster contributes zero', 'merge appearance matches pre-merge full composite; undo reconstructs graph', 'unmodified source assets retain original hashes'])
    add('transform-canvas', ['edge64', 'layered3'], 'Translate selected layer by (4,8); rotate 90 degrees; resize canvas to 80x64 with center anchor; crop to [16,16,48,48]; zoom actual pixels and fit; undo each stage.',
        ['document-space feature coordinates follow declared transform mapping', 'crop output dimensions=32x32; original raster bytes unchanged', 'undo restores 64x64 canvas and original layer transform', 'guide/grid snapping uses declared targets; zoom changes viewport only'])
    add('selection', ['edge64'], 'Select rectangle [16,16,48,48]; add [0,0,8,8]; subtract [24,24,40,40]; invert; feather 2 pixels; copy/paste selected pixels; cancel a pending lasso.',
        ['selection membership at (20,20)=true before inversion, (32,32)=false after subtract', 'feather adds intermediate edge coverage without changing unselected far pixels', 'paste preserves RGBA and makes an undoable layer', 'cancel pending selection leaves committed document/selection unchanged'])
    add('retouch', ['edge64', 'layered3', 'real-raw'], 'Clone source (20,20) to (52,52) with opaque hard brush; heal a black defect at (32,32); change upstream RAW exposure; reopen and replay persisted sampled commands.',
        ['clone target equals declared upstream source under sampling/mask policy', 'heal removes isolated defect while unchanged far pixels remain identical', 'retouch replay follows source-coordinate mapping after RAW recipe change', 'undo removes stroke and original source hash stays identical'])
    add('paint', ['edge64'], 'Paint red center stroke at (8,8) with size=4, hardness=1, opacity=1; erase same point; repeat with pressure input and selection restricting x<16; undo.',
        ['hard fully covered center is red opaque; eraser reduces alpha without overwriting original source', 'pixels outside selection stay identical', 'document-space stroke alignment survives zoom and viewport changes', 'one completed stroke creates one undoable command; pressure/size policy agrees with source settings'])
    add('text-shape-gradient', ['edge64'], 'Insert editable text LensWorks; set font size=24 and tracking=10; add 16x16 rectangle and ellipse; draw foreground-red/background-blue linear and radial gradients; reopen and edit parameters.',
        ['text remains editable text with string/style/layout retained', 'vector kind/fill/stroke/transform retained rather than raster-only replacement', 'gradient endpoint colors follow foreground/background and alpha mode', 'reopen preserves parameter values and undo returns preceding state'])
    add('history-persistence', ['layered3'], 'Snapshot A; add raster layer and name checkpoint BeforeRetouch; paint one stroke; undo/redo; save; terminate/reopen; restore checkpoint; prune unprotected history.',
        ['undo returns exact A layer graph/pixels; redo restores stroke', 'reopen retains persistent history and named checkpoint', 'checkpoint and referenced source assets remain available when oldest unprotected steps are pruned', 'version edits do not alter sibling version or original source'])
    add('autosave-recovery', ['layered3', 'catalog-two'], 'Crash at each boundary before/after editor asset publication and catalog-membership commit; relaunch; recover draft; resume first Save/Add to Catalog.',
        ['recovered latest durable document has valid assets and source IDs', 'no phantom catalog membership or duplicate document identity', 'no success reported before durable commit', 'existing original hashes unchanged; incomplete publications cleaned or resumed'])
    add('document-exchange', ['layered3'], 'Save native package; reopen; import retained PSD and PSB test fixtures with groups/masks/text/adjustments; exercise external-change conflict; export required layered exchange and reopen it.',
        ['native layer UUID graph and editable settings round-trip', 'PSD/PSB conversion reports identify unsupported payload without silent loss', 'layered export needs a real writer: reader-only success cannot satisfy this observable', 'malformed/oversized fixture is rejected without replacing current document'])
    add('export', ['hdr2', 'layered3'], 'Export complete document as JPEG quality=90 with white matte, PNG16 preserve alpha, TIFF32f linear-sRGB and selectable RGB ICC; fit to 32x32 without upscaling; decode bytes; inject output-write failure.',
        ['full layer/RAW/effect result appears, not only source recipe', 'PNG16 reports 16 bits/sample and alpha; TIFF32f reports float samples preserving allowed HDR values', 'JPEG has explicit matte and no alpha; embedded profile matches selected RGB profile', 'fit dimensions obey aspect ratio; source bytes unchanged; failed publication creates no falsely successful output'])
    add('backup', ['catalog-two', 'layered3'], 'Back up catalog with linked versions/source revisions/editor assets; restore to second folder while originals offline; interrupt/resume job; corrupt one backed-up asset and retry restore.',
        ['original image IDs, layer graph/history/checkpoints and referenced assets remain available', 'rebuildable preview semantics retained', 'resuming does not repeat completed output or replace source identity', 'corrupt asset checksum rejects incomplete restore; source backup remains unchanged'])
    add('native-input', ['layered3'], 'Focus canvas, text editor and numeric field in turn; invoke this exact source command/chord/control; save custom shortcut; reopen settings; exercise cancel/default buttons; test VoiceOver names and focus route.',
        ['canvas shortcut invokes its specified command once; text entry consumes text keys', 'custom chord persists and Restore Defaults removes override', 'cancel leaves edited settings/document unchanged; disabled state follows source preconditions', 'accessibility name/action and focus order expose the same control'])
    add('distribution', ['layered3'], 'Launch packaged signed native application; open known document via file association; inspect update configuration; exercise disabled/unconfigured feed and approved update path.',
        ['document opens in native editor with readable source refs', 'package retains required third-party notices', 'unconfigured/unapproved feed performs no download and reports correct state', 'approved update signature/version checks reject invalid package'])
    add('performance-measurement', ['layered3'], 'Measure native interaction/preview/export on target device under approved resource ownership and record device/OS/revision; repeat same trace only under story authorization.',
        ['raw timing/memory samples saved with trace inputs and device identity', 'limits use sc-24694 approved measured acceptance rather than inherited Compositor numbers', 'no concurrent resource campaign launched by inventory audit'])
    # Exact non-default effect settings and spatial assertions.
    effects = {
        'stroke': ({'size': 4, 'inside': False, 'color': [1,0,0], 'opacity': 1}, ['red outline appears outside edge64 square; center pixels unchanged', 'inside=true keeps effect inside alpha support']),
        'shadow': ({'angle': 90, 'distance': 8, 'blur': 0, 'opacity': 1}, ['shadow offset=(0,+8) in top-down layer pixels', 'original square color/alpha unchanged']),
        'colorOverlay': ({'color': [1,0,0], 'opacity': 1}, ['opaque covered square center becomes red; zero-alpha exterior remains zero-alpha']),
        'innerShadow': ({'angle': 90, 'distance': 4, 'blur': 0, 'opacity': 1}, ['darkening occurs inside alpha support; outside stays transparent']),
        'outerGlow': ({'size': 4, 'color': [1,1,1], 'opacity': 1}, ['nonzero glow alpha occurs outside square boundary; square interior retains source behavior']),
        'innerGlow': ({'size': 4, 'color': [1,0,0], 'opacity': 1}, ['red glow appears inside square edge; outside stays transparent']),
    }
    for name, (params, expected) in effects.items():
        add('effect-' + name, ['edge64'], f'Enable {name}; apply specified settings; compare isolated effect alpha/color; disable, undo, save/reopen.', expected + ['disabled effect contributes zero and settings survive reopen'], params)
    filters = {
        'gaussianBlur': ({'radius': 2}, ['isolated black/white edge spreads; opaque flat gray remains spatially constant']),
        'motionBlur': ({'angle': 0, 'distance': 8}, ['impulse spreads along horizontal direction; flat field remains constant']),
        'addNoise': ({'amount': 10, 'gaussian': False, 'monochromatic': True, 'seed': 42}, ['same seed yields same pixels; changed seed changes pattern; monochromatic channel offsets agree']),
        'vignette': ({'vignetteAmount': 50, 'vignetteColor': [0,0,0]}, ['flat-image edge luminance decreases relative to center; alpha policy retained']),
        'bloomGlow': ({'bloomAmount': 40, 'bloomRadius': 4}, ['bright impulse adds surrounding glow; disabling returns original']),
        'dither': ({'style': 'atkinson', 'colors': 'blackWhite'}, ['output opaque samples use only selected black/white palette; fixed settings reproduce exact pattern']),
        'tonalContrast': ({'tonalAmount': 50, 'tonalRadius': 4}, ['local edge contrast changes; flat gray remains spatially constant']),
        'lensCorrection': ({'distortion': 20}, ['straight-grid coordinates follow pinned radial warp reference; zero distortion is identity']),
        'cameraRaw': ({'exposure': 1, 'contrast': 20}, ['nonzero recipe changes tone; resetting all settings produces identity; source alpha retained']),
        'removeBackground': ({'backgroundQuality': 'advanced', 'refineEdges': 12, 'matteContrast': 25, 'shiftEdge': 0}, ['subject fixture interior remains revealed and distant background masked; basic/advanced routes report actual supported mask result']),
        'contentAwareFill': ({'selection': [30,30,34,34]}, ['isolated black defect in white area is replaced; unselected far pixels remain identical']),
        'curves': ({'points': [[0,0],[128,190],[255,255]]}, ['black/white endpoints retained; middle ramp increases; per-channel curve preserves untouched channels']),
        'exposure': ({'exposure': 1, 'offset': 0, 'gamma': 1}, ['exposure increases working luminance by source formula; zero-stop offset=0 gamma=1 is identity']),
        'gradientMap': ({'stops': [[0,[1,0,0]],[1,[0,0,1]]]}, ['black endpoint maps to red and white endpoint to blue; source alpha retained']),
        'grain': ({'amount': 20, 'size': 2, 'roughness': 50}, ['deterministic seeded grain changes flat-field texture; tiled/full render share one document-space pattern']),
        'blackWhite': ({'red': 40, 'yellow': 60, 'green': 40, 'cyan': 60, 'blue': 20, 'magenta': 80}, ['output RGB channels are equal for each opaque color sample; alpha retained']),
        'colorBalance': ({'cyanRed': 20, 'magentaGreen': 0, 'yellowBlue': 0}, ['red/cyan tonal balance changes with declared luminance-preservation policy; neutral settings are identity']),
        'hsv': ({'hue': 120, 'saturation': 0, 'lightness': 0, 'colorize': False}, ['primary-red sample rotates toward green; alpha retained; neutral HSV is identity']),
        'levels': ({'black': 0, 'gamma': 1, 'white': 255, 'outputBlack': 0, 'outputWhite': 255}, ['default levels are identity; narrowed input range remaps endpoints and preserves source alpha']),
        'invert': ({}, ['opaque red becomes cyan in baseline byte-space fixture; double inversion restores color; alpha unchanged']),
    }
    for name, (params, expected) in filters.items():
        add('filter-' + name, ['ramp256', 'rgba-four', 'edge64'], f'Apply {name} to full raster and selection, then as adjustment layer where supported; cancel preview, commit, undo and save/reopen.', expected + ['outside selection unchanged; cancel retains original; undo restores source; editable settings round-trip where supported'], params)
    # Each blend case carries the exact expected scalar formula from the frozen
    # source/reference rather than treating every mode as one generic category.
    blend_names = ('normal darken multiply colorBurn linearBurn lighten screen colorDodge linearDodge overlay softLight hardLight vividLight linearLight pinLight hardMix difference exclusion subtract divide hue saturation color luminosity').split()
    for name in blend_names:
        add('blend-' + name, ['rgba-four', 'hdr2'], f'Composite source=(0.75,0.25,0.5) over backdrop=(0.25,0.5,0.75) with blend={name}, at opacity=1 and 0.5; repeat mask=0; compare scalar reference then tile/full output.',
            [f'RGB equals independent {name} reference defined by frozen SeparableBlend/LayerBlendMode/PSD blend tests (use exact named-mode oracle, then approved linear-space policy)', 'mask=0 or opacity=0 leaves backdrop unchanged', 'alpha composition agrees with declared straight/premultiplied contract', 'save/reopen retains exact named blend mode'], {'source_rgb': [0.75,0.25,0.5], 'backdrop_rgb': [0.25,0.5,0.75], 'blend': name, 'opacity': [1,0.5,0]})
    tool_actions = {
        'move': ('Translate square by (4,8) using Move tool.', ['square origin changes from (16,16) to (20,24); raster data unchanged']),
        'marquee': ('Drag rectangle (16,16) to (48,48).', ['center selected; point (8,8) unselected; Shift/Option combine matches declared selection mode']),
        'lasso': ('Click polygon (16,16),(48,16),(48,48),(16,48), close it, then cancel another unfinished lasso.', ['first polygon selects center; cancelled polygon does not change committed selection']),
        'wand': ('Click opaque square with tolerance=0; toggle contiguous and Object mode with Tab.', ['matching connected opaque pixels selected; transparent exterior excluded; mode switch visible']),
        'crop': ('Crop document to rectangle [16,16,48,48], commit and undo.', ['committed canvas=32x32; undo returns 64x64; original asset hash unchanged']),
        'brush': ('Paint opaque red hard-size-4 dab at (8,8); switch Eraser and erase same point.', ['fully covered center red before erasing; alpha decreases after erase; outside footprint unchanged']),
        'spotHealing': ('Paint over isolated black defect in white square.', ['defect replaced from surrounding content; far pixels unchanged; one undoable sampled command']),
        'cloneStamp': ('Option-click source (20,20), paint target (8,8).', ['target copies white upstream source; source marker/alignment retained; one undoable sampled command']),
        'blur': ('Blur hard edge; Tab through Blur/Smudge/Liquify; drag under each declared mode.', ['blur softens edge; smudge transports sampled color along stroke; liquify moves geometry; undo restores each']),
        'gradient': ('Draw red-to-blue linear gradient from (0,0) to (63,0); switch radial and foreground-to-transparent.', ['endpoint color/alpha follow selected mode; gradient operation is undoable']),
        'shape': ('Draw rectangle (4,4)-(20,20); Shift-U switches ellipse; choose line.', ['editable vector kind, geometry, fill and stroke retained after reopen']),
        'type': ('Click (8,8), type LensWorks, command-Return commits; edit text after reopen.', ['string remains editable text; text focus handles typing; cancel leaves prior committed string']),
        'eyedropper': ('Sample pure red pixel using foreground/background modifier routes.', ['correct chosen palette color becomes [1,0,0]; canvas pixels unchanged']),
        'hand': ('Drag viewport by (20,10), then hold Space temporarily from Brush.', ['pan changes viewport only; releasing Space restores Brush; no brush stroke committed']),
        'zoom': ('Zoom at canvas point (32,32); choose actual pixels then fit.', ['anchor remains under pointer; actual pixels scale=1; document/layer bytes unchanged']),
        'idle': ('Select idle with A and click/drag canvas.', ['no editing tool selected; click/drag creates no layer, stroke or selection']),
    }
    for name, (action, expected) in tool_actions.items(): add('tool-' + name, ['edge64'], action, expected + ['undo and save/reopen preserve documented committed/transient state'])
    return p

def surface_for(row):
    if row['kind'] == 'format_route': return 'declared_control_or_service'
    if row['kind'] in {'type', 'support_operation', 'native_operation', 'rust_constant', 'source_export'}: return 'implementation_support'
    if row.get('visibility') == 'private': return 'implementation_support'
    if row['file'].endswith('.rs') and row.get('visibility') != 'public': return 'implementation_support'
    if row['kind'] == 'setting_or_field' and ('{' in row['declaration'] or 'private' in row['declaration']): return 'implementation_support'
    return 'declared_control_or_service'

def fixture_profile_for(row):
    symbol = row['symbol']
    if row['kind'] == 'enum_case':
        owner, case = symbol.rsplit('.', 1)
        if owner == 'NavigationTool': return 'tool-' + case
        if owner in {'AdjustmentKind', 'FilterKind'}: return 'filter-' + case
        if owner == 'LayerEffectKind': return 'effect-' + case
        if owner == 'LayerBlendMode': return 'blend-' + case
    for owner, profile in {'StrokeEffect': 'stroke', 'ShadowEffect': 'shadow', 'ColorOverlayEffect': 'colorOverlay', 'InnerShadowEffect': 'innerShadow', 'OuterGlowEffect': 'outerGlow', 'InnerGlowEffect': 'innerGlow'}.items():
        if symbol.startswith(owner + '.'): return 'effect-' + profile
    if row['story_id'] == 'sc-24666':
        lower = (symbol + ' ' + row['file']).lower()
        for pattern, profile in (('huesaturation', 'hsv'), ('curves', 'curves'), ('levels', 'levels'), ('exposuresettings', 'exposure'), ('gradientmap', 'gradientMap'), ('grain', 'grain'), ('blackwhite', 'blackWhite'), ('colorbalance', 'colorBalance'), ('dither', 'dither'), ('vignette', 'vignette'), ('bloom', 'bloomGlow'), ('tonal', 'tonalContrast'), ('distortion', 'lensCorrection'), ('noise', 'addNoise')):
            if pattern in lower: return 'filter-' + profile
    if symbol.startswith('Catalog.') and row['story_id'] in {'sc-24658', 'sc-24659'}: return 'catalog-service'
    return {'sc-24658': 'catalog-adapter', 'sc-24659': 'catalog-service', 'sc-24660': 'metadata-organization',
            'sc-24661': 'offline-relink', 'sc-24662': 'migration', 'sc-24663': 'raw-develop', 'sc-24664': 'precision-render',
            'sc-24665': 'layer-graph', 'sc-24666': 'filter-cameraRaw', 'sc-24667': 'transform-canvas', 'sc-24668': 'selection',
            'sc-24669': 'paint', 'sc-24670': 'retouch', 'sc-24671': 'text-shape-gradient', 'sc-24672': 'history-persistence',
            'sc-24674': 'autosave-recovery', 'sc-24675': 'document-exchange', 'sc-24676': 'export', 'sc-24677': 'backup',
            'sc-24689': 'native-input', 'sc-24690': 'distribution', 'sc-24694': 'performance-measurement'}[row['story_id']]

def fixture_parameters(row):
    result = {'source_symbol': row['symbol'], 'source_declaration': row['declaration'], 'source_anchor': row['file'] + ':' + str(row['line'])}
    if row['kind'] in {'enum_case', 'format_route', 'desktop_variant'}: result['selected_case_or_route'] = row['symbol']
    leaf = row['symbol'].split('.')[-1].lower()
    if row['kind'] in {'setting_or_field', 'variant_field', 'control_binding', 'desktop_field'}:
        if any(x in leaf for x in ('opacity', 'alpha', 'hardness')): value = 0.5
        elif any(x in leaf for x in ('enabled', 'visible', 'monochrom', 'preserve', 'colorize', 'gaussian', 'contiguous', 'snap', 'allow_', 'shows')): value = not ('= true' in row['declaration'])
        elif any(x in leaf for x in ('temperature', 'kelvin')): value = 6500
        elif any(x in leaf for x in ('angle', 'degrees', 'hue', 'rotation')): value = 30
        elif any(x in leaf for x in ('size', 'radius', 'distance', 'width', 'height')): value = 4
        elif any(x in leaf for x in ('red', 'green', 'blue')): value = 0.25
        elif any(x in leaf for x in ('exposure', 'gamma', 'contrast', 'amount', 'saturation', 'strength')): value = 1
        else:
            default = re.search(r'=\s*([^{}]+)', row['declaration'])
            value = default.group(1).strip() if default else 'value supplied by the named fixture profile / exact public DTO'
        result['exercise_value'] = value
        result['additional_case'] = 'retained source rejection/default case from the referenced baseline test, plus save/reopen where serialized'
    return result

def test_index(files):
    result = []
    for path in files:
        text = path.read_text(errors='replace')
        patterns = []
        if path.suffix == '.swift': patterns = [r'\bfunc\s+(test\w+)\s*\(', r'@Test[\s\S]{0,600}?\bfunc\s+(\w+)\s*\(']
        elif path.suffix == '.rs': patterns = [r'#\[(?:tokio::)?test(?:\([^]]*\))?\][\s\S]{0,500}?\b(?:async\s+)?fn\s+(\w+)']
        elif path.suffix in {'.ts', '.tsx'}: patterns = [r'\b(?:it|test)\s*\(\s*[\'"]([^\'"\n]+)']
        seen = set()
        for pattern in patterns:
            for m in re.finditer(pattern, text):
                if (m.group(1), text.count('\n', 0, m.end())) in seen: continue
                seen.add((m.group(1), text.count('\n', 0, m.end())))
                start = text.find('{', m.end())
                clean = mask(text)
                n = 1
                end = start + 1
                while start >= 0 and end < len(clean) and n:
                    n += (clean[end] == '{') - (clean[end] == '}')
                    end += 1
                body = text[start:end] if start >= 0 else ''
                rel = str(path.relative_to(ROOT))
                line = text.count('\n', 0, m.start()) + 1
                result.append({'id': 'test-' + digest(f'{rel}:{line}:{m.group(1)}'.encode())[:16],
                               'file': rel, 'line': line,
                               'symbol': m.group(1), 'tokens': sorted(set(re.findall(r'\b[A-Za-z_]\w*\b', body))),
                               'status': 'source_present_not_run'})
    return result

def special_rows():
    rows = []
    def add(path, line, symbol, kind, note):
        rows.append({'file': path, 'line': line, 'kind': kind, 'symbol': symbol, 'declaration': note})
    path = 'vendor/Compositor/Compositor/UI/KeyboardShortcuts.swift'
    text = (ROOT / path).read_text()
    # Expanded loops in ShortcutDefinition.all are independent named controls.
    for m in re.finditer(r'\("([^"\n]+)",\s*"((?:\\.|[^"\\])*)"\)', text):
        if 60 <= text.count('\n', 0, m.start()) + 1 <= 128:
            if m.group(1) in {'Left', 'Right', 'Up', 'Down'}: continue
            add(path, text.count('\n', 0, m.start()) + 1, m.group(1), 'keyboard_expansion', m.group(0))
    for digit in range(10): add(path, 114, f'Opacity digit {digit}', 'keyboard_expansion', 'ShortcutDefinition.all: opacity digit loop')
    for direction in ('Left', 'Right', 'Up', 'Down'):
        for operation in ('Nudge', 'Move selected pixels'):
            for amount in (1, 10): add(path, 116 if operation == 'Nudge' else 117, f'{operation} {direction} {amount} px', 'keyboard_expansion', 'ShortcutDefinition.all: direction/amount loop')
    for target in ('Decrease tracking', 'Increase tracking', 'Decrease leading', 'Increase leading'):
        add(path, 123, target + ' by 10', 'keyboard_expansion', 'ShortcutDefinition.all: text tracking/leading loop')
    add(path, 119, 'Finish editing text', 'keyboard_expansion', 'ShortcutDefinition.all: command-Return')
    # Explicit importer/exporter routes; type recognition never promises a camera.
    p = 'vendor/Compositor/Compositor/IO/ImageImporter.swift'
    for fmt in ('JPEG', 'PNG', 'HEIC', 'TIFF'):
        add(p, 60, 'raster import:' + fmt, 'format_route', 'ImageImporter.decode: ImageIO, orientation, RGBA8 sRGB conversion')
    add(p, 34, 'rasterized SVG import', 'format_route', 'decodeSVG: NSImage renderer; does not preserve editable SVG paths')
    add(p, 59, 'flattened PSD import', 'format_route', 'flattenedPhotoshop accepts photoshopImage when explicitly requested')
    add(p, 59, 'flattened PSB import', 'format_route', 'flattenedPhotoshop accepts photoshopLargeImage when explicitly requested')
    add(p, 87, 'layered PSD import', 'format_route', 'loadPhotoshop -> PSDReader, conversion report required')
    add(p, 87, 'layered PSB import', 'format_route', 'loadPhotoshop -> PSDReader; large-format version handling')
    p = 'vendor/Compositor/Compositor/IO/RawImporter.swift'
    add(p, 75, 'system-recognized camera RAW import', 'format_route', 'UTType.rawImage recognition plus CIRAWFilter admission; installed macOS decoder determines cameras; import-time RGBA8 is baseline only')
    p = 'vendor/Compositor/Compositor/IO/ImageExporter.swift'
    text = (ROOT / p).read_text()
    for fmt, token in (('PNG', 'func pngData'), ('JPEG', 'func jpegData')):
        pos = text.find(token)
        if pos >= 0: add(p, text.count('\n', 0, pos) + 1, 'raster export:' + fmt, 'format_route', 'ImageExporter: frozen flattened export, no PSD/PSB writer')
    p = 'engines/catalog/src/media.rs'
    text = (ROOT / p).read_text()
    match = re.search(r'pub fn supported_extension[\s\S]*?\n}', text)
    if match:
        for fmt in re.findall(r'"(\w+)"', match.group()):
            pos = text.find('"' + fmt + '"', match.start())
            add(p, text.count('\n', 0, pos) + 1, 'catalog import extension:' + fmt, 'format_route', 'supported_extension admission; actual decode, camera and malformed-file acceptance still required')
    return rows

def build():
    files = paths()
    tests = test_index(files)
    by_token = collections.defaultdict(list)
    for test in tests:
        for token in test['tokens']:
            if len(token) > 3: by_token[token].append(test)
    file_records, capabilities = [], []
    for path in files:
        rel = str(path.relative_to(ROOT))
        source_rows = extract(path)
        role = 'baseline_test_source' if is_test(path) else 'baseline_product_source'
        file_records.append({'file': rel, 'sha256': digest(path.read_bytes()), 'role': role,
                             'story_id': story_for(rel), 'declaration_count': len(source_rows)})
        # Test declarations are evidence; product files may also contain inline
        # Rust tests. Keep the full source surface without inventing acceptance.
        if role == 'baseline_test_source': continue
        for row in source_rows:
            if row['kind'] == 'baseline_test': continue
            row['file'] = rel
            capabilities.append(row)
    capabilities.extend(special_rows())
    for row in capabilities:
        row['id'] = 'cap-' + digest(f"{row['file']}:{row['line']}:{row['kind']}:{row['symbol']}".encode())[:16]
        row['story_id'] = story_for(row['file'], row['symbol'])
        row['terminal_story_id'] = 'sc-24691'
        row['surface'] = surface_for(row)
        row['baseline_status'] = 'source_present_not_qualified_in_lensworks'
        leaf = row['symbol'].split('.')[-1]
        owner = row['symbol'].split('.')[0] if '.' in row['symbol'] else None
        row['baseline_test_references'] = [t['id'] for t in by_token.get(leaf, [])
                                           if t['file'].split('/')[1] == row['file'].split('/')[1]
                                           and (owner in t['tokens'] if owner else len(leaf) >= 8)]
        row['test_evidence_semantics'] = 'leaf symbol and declaring type tokens occur in baseline test body (or a free-function token at least 8 characters); IDs resolve in baseline_test_cases. Reference only, not assertion coverage or passing evidence.'
        if row['surface'] == 'implementation_support':
            row['acceptance_fixture'] = {'id': 'source-provenance/' + row['id'], 'status': 'provenance_only', 'profile_id': None, 'parameters': None, 'execution_evidence': None}
        else:
            row['acceptance_fixture'] = {'id': 'lensworks/' + row['story_id'] + '/' + row['id'], 'status': 'planned',
                                         'profile_id': fixture_profile_for(row), 'parameters': fixture_parameters(row),
                                         'baseline_regression_case_ids': row['baseline_test_references'], 'execution_evidence': None}
    licenses = [p for baseline in PINS for p in baseline_root(baseline).rglob('*')
                if p.is_file() and '.git' not in p.parts and ('LICENSE' in p.name or 'NOTICE' in p.name)]
    return {'schema_version': 1, 'scope': 'Every first-party frozen product source file plus every extracted enum variant, declared field, operation, UI control, input binding, keyboard expansion and explicit format route. Transitive third-party implementation source is license-accounted separately.',
            'baselines': [{'name': name, 'revision': pin, 'source': str(baseline_root(name).relative_to(ROOT)), **({'source_digest': catalog_source.verify()} if name == 'PhotoCatalog' else {})} for name, pin in PINS.items()],
            'provenance_files': ['DEPENDENCIES.json', 'THIRD_PARTY_NOTICES.md'],
            'licenses': [{'file': str(p.relative_to(ROOT)), 'sha256': digest(p.read_bytes())} for p in sorted(licenses)],
            'limitations': [
                'Declaration inventory is intentionally broader than user-visible capability count; implementation-support rows are marked separately.',
                'The lexical extractor is conservative, not a Swift/Rust/TypeScript compiler. File hashes, declaration-set comparison, explicit enum/format/keyboard checks and full file list prevent silent source changes; they do not prove semantic acceptance.',
                'Exposed capabilities have planned semantic fixture profiles with individual source parameters; support declarations are provenance-only and are not presented as executable fixtures. Baseline test bodies are indexed as source evidence; this audit does not run them.',
                'Compositor RAW import and Camera Raw Filter are RGBA8 baseline behavior, not live-RAW acceptance. Every retained pixel tool/kernel requires float/color-contract qualification.',
                'System RAW recognition is dynamic. Freeze representative real camera fixtures per target macOS version; no enumerated camera support claim follows from UTType.rawImage.',
                'PSD/PSB readers and conversion reports do not establish layered PSD/PSB export; sc-24675/sc-24676 own required writer and compatibility validation.',
                'Existing PhotoCatalog image exports render its photo recipe. LensWorks must substitute the full layered live-RAW document render, preserve source identity, and adapt export provenance.',
                'PhotoCatalog private/transport operations are retained behavior contracts mapped to adapter stories, not a promise to preserve the React/Tauri implementation.',
                'Conditional Rust test modules embedded in product files are conservatively retained as support rows; baseline_test_cases identifies test evidence separately.',
                'PhotoCatalog itself has no root license file at this pin; application ownership/licensing needs owner disposition while third-party notices are retained.',
            ],
            'fixture_assets': fixture_assets(), 'fixture_profiles': fixture_profiles(),
            'files': file_records, 'capabilities': sorted(capabilities, key=lambda r: (r['file'], r['line'], r['kind'], r['symbol'])),
            'baseline_test_cases': [{k: v for k, v in t.items() if k != 'tokens'} for t in tests]}

def markdown(data):
    rows = data['capabilities']
    counts = collections.Counter(r['story_id'] for r in rows)
    kinds = collections.Counter(r['kind'] for r in rows)
    covered = sum(bool(r['baseline_test_references']) for r in rows)
    exposed = [r for r in rows if r['surface'] != 'implementation_support']
    passing = sum(r['acceptance_fixture']['status'] == 'passing' for r in exposed)
    fixtures = 'planned fixtures' if not passing else f'fixtures ({passing} passing with recorded native test evidence, {len(exposed) - passing} planned)'
    evidence = 'None are native acceptance evidence.' if not passing else 'Rows marked passing name the native tests that exercise them in `execution_evidence`; integrated acceptance remains with `sc-24691`, and no other row is native acceptance evidence.'
    out = ['# Frozen capability inventory', '',
           f"{len(rows)} source-surface rows across {len(data['files'])} audited source files; {len(exposed)} declared controls/services have {fixtures}; {len(rows)-len(exposed)} support declarations are provenance-only; {len(data['baseline_test_cases'])} baseline test cases indexed. {evidence}", '',
           'This ledger is deliberately finer than a feature checklist: each enum case, configuration field, command/control, exposed service operation and format route gets its own source anchor, story and fixture. Implementation-support declarations remain separately labeled; the row count is not a user-visible feature count.', '',
           'Run `python3 scripts/audit-capabilities.py` from any working directory. It re-extracts source anchors and verifies frozen refs, file digests, story membership, fixture identities, baseline tests, provenance and license digests. Regeneration with `--write` updates only this JSON and Markdown ledger, keeps each recorded result on the row with the same capability ID and refuses to drop one; review mappings before accepting a new baseline.', '',
           '## Frozen provenance', '']
    for b in data['baselines']: out.append(f"- {b['name']}: `{b['revision']}` at `{b['source']}`.")
    out += ['', 'See `DEPENDENCIES.json` and `THIRD_PARTY_NOTICES.md`; individual retained license/notice hashes live in JSON.', '', '## Limits and unresolved qualification', '']
    out += ['- ' + s for s in data['limitations']]
    out += ['', f'{covered} rows reference baseline test bodies. These are discovery pointers only: tests have not been executed by this inventory task, and token mention does not establish assertion coverage.', '', '## Story coverage', '', '| Story | Source-surface rows | Fixture status |', '| --- | ---: | --- |']
    for story, count in sorted(counts.items()):
        states = collections.Counter(r['acceptance_fixture']['status'] for r in exposed if r['story_id'] == story)
        status = 'planned' if set(states) <= {'planned'} else ', '.join(f'{states[k]} {k}' for k in ('passing', 'failing', 'blocked', 'planned') if states[k])
        out.append(f'| {story} | {count} | exposed: {status}; support: provenance-only |')
    out += ['', 'The complete 37-story plan includes new AI/version/recovery and distribution requirements beyond frozen behavior. Absence of baseline rows for a story does not remove those requirements; the epic requirements and story AC remain authoritative. `sc-24691` reviews every inventory row at integrated acceptance.', '', '## Extracted surface kinds', '', '| Kind | Rows |', '| --- | ---: |']
    out += [f'| {kind} | {count} |' for kind, count in sorted(kinds.items())]
    out += ['', '## Concrete fixture profiles', '', 'Asset recipes and exact per-capability parameter bindings live in JSON. Profiles are planned specifications; fixture construction/execution is still required by the owning story. Every enum variant and source parameter remains separately bound rather than being waived by the shared recipe.', '']
    for name, profile in data['fixture_profiles'].items():
        out += ['### ' + name, '', 'Inputs: ' + ', '.join(profile['asset_ids']) + '.', '', profile['action'], '']
        if profile['parameters']: out += ['Parameters: `' + json.dumps(profile['parameters']) + '`.', '']
        out += ['- ' + observable for observable in profile['expected_observables']]
        out.append('')
    out += ['## Complete declared control and service mapping', '', 'Fixture IDs are `lensworks/<story>/<capability ID>`; each JSON row carries its concrete profile, individual parameters, planned status, declaration excerpt and baseline test IDs resolving to file/line/symbol in `baseline_test_cases`. References require declaring-type and leaf-symbol tokens together, or a free-function token of at least eight characters. Implementation-support rows remain complete in JSON, mapped to their owning stories, with provenance-only status.', '', '| Capability ID | Source file:line | Symbol/control | Kind | Owner | Profile | Test references |', '| --- | --- | --- | --- | --- | --- | ---: |']
    for r in exposed:
        label = r['symbol'].replace('|', '\\|').replace('\n', ' ')
        out.append(f"| {r['id']} | `{r['file']}:{r['line']}` | `{label}` | {r['kind']} | {r['story_id']} | {r['acceptance_fixture']['profile_id']} | {len(r['baseline_test_references'])} |")
    out += ['', '## File ledger', '', '| File | Role | Owner | Extracted declarations | SHA-256 |', '| --- | --- | --- | ---: | --- |']
    for f in data['files']: out.append(f"| `{f['file']}` | {f['role']} | {f['story_id']} | {f['declaration_count']} | `{f['sha256']}` |")
    return '\n'.join(out) + '\n'

def audit(data, actual):
    errors = []
    stories = set(re.findall(r'^\| \[sc-(\d+)\]', (ROOT / 'docs/SHORTCUT_STORIES.md').read_text(), re.M))
    valid = {'sc-' + s for s in stories}
    if len(valid) != 37: errors.append(f'expected 37 story identities, found {len(valid)}')
    catalog_source.verify()
    for name, pin in (('Compositor', PINS['Compositor']),):
        head = subprocess.check_output(['git', '-C', str(ROOT / 'vendor' / name), 'rev-parse', 'HEAD'], text=True).strip()
        if head != pin: errors.append(f'{name} HEAD {head} != frozen {pin}')
    dependencies = json.loads((ROOT / 'DEPENDENCIES.json').read_text())
    for name, pin in PINS.items():
        if dependencies.get(name, {}).get('revision') != pin: errors.append(f'{name}: dependency manifest revision differs')
    for provenance in data.get('provenance_files', []):
        if not (ROOT / provenance).is_file(): errors.append('missing provenance file ' + provenance)
    if data['baselines'] != actual['baselines']: errors.append('baseline provenance differs')
    if data.get('fixture_assets') != actual['fixture_assets']: errors.append('fixture asset recipes incomplete/changed')
    if data.get('fixture_profiles') != actual['fixture_profiles']: errors.append('fixture profiles incomplete/changed')
    for name, profile in data.get('fixture_profiles', {}).items():
        if not profile.get('asset_ids') or not profile.get('action') or not profile.get('expected_observables'): errors.append('incomplete fixture profile ' + name)
        if any(asset not in data['fixture_assets'] for asset in profile.get('asset_ids', [])): errors.append('unknown fixture asset in ' + name)
    for section in ('files', 'licenses', 'baseline_test_cases'):
        if data[section] != actual[section]: errors.append(f'{section} missing, added, changed or incorrectly mapped')
    expected = {r['id']: r for r in actual['capabilities']}
    recorded = {r['id']: r for r in data['capabilities']}
    if len(recorded) != len(data['capabilities']): errors.append('duplicate capability IDs')
    for key in sorted(expected.keys() - recorded.keys()): errors.append('missing capability mapping ' + key)
    for key in sorted(recorded.keys() - expected.keys()): errors.append('unknown/stale capability ' + key)
    fixtures = set()
    for key, row in recorded.items():
        if row.get('story_id') not in valid: errors.append(f'{key}: invalid/missing story ID')
        if row.get('terminal_story_id') != 'sc-24691': errors.append(f'{key}: missing terminal review')
        fixture = row.get('acceptance_fixture', {})
        if fixture.get('id') in fixtures: errors.append(f'{key}: duplicate fixture ID')
        fixtures.add(fixture.get('id'))
        if row.get('surface') == 'implementation_support':
            if fixture.get('status') != 'provenance_only' or fixture.get('profile_id') is not None: errors.append(f'{key}: support declaration presented as acceptance')
        else:
            if not fixture.get('id', '').startswith('lensworks/' + row.get('story_id', '') + '/') or fixture.get('profile_id') not in data.get('fixture_profiles', {}): errors.append(f'{key}: missing/invalid acceptance fixture profile')
            if not fixture.get('parameters', {}).get('source_symbol') or not fixture.get('parameters', {}).get('source_anchor'): errors.append(f'{key}: missing concrete source parameter binding')
        if fixture.get('status') not in {'planned', 'passing', 'failing', 'blocked', 'provenance_only'}: errors.append(f'{key}: invalid fixture status')
        if fixture.get('status') == 'passing' and not fixture.get('execution_evidence'): errors.append(f'{key}: passing fixture has no execution evidence')
        if key in expected:
            for field in ('file', 'line', 'kind', 'symbol', 'declaration', 'visibility', 'surface', 'baseline_test_references'):
                if row.get(field) != expected[key].get(field): errors.append(f'{key}: source evidence drift in {field}')
    for f in data['files']:
        if f.get('story_id') not in valid: errors.append(f"{f['file']}: unmapped source file")
    # Critical source primitives protect against accidentally weakening extractor
    # semantics without changing source hashes.
    enum_cases = collections.defaultdict(set)
    for r in data['capabilities']:
        if r['kind'] == 'enum_case':
            typ, case = r['symbol'].rsplit('.', 1)
            enum_cases[typ].add(case)
    for typ, required in {
        'NavigationTool': {'move', 'marquee', 'lasso', 'wand', 'crop', 'brush', 'spotHealing', 'cloneStamp', 'blur', 'gradient', 'shape', 'type', 'eyedropper', 'hand', 'zoom', 'idle'},
        'AdjustmentKind': {'hsv', 'levels', 'curves', 'exposure', 'gradientMap', 'grain', 'addNoise', 'gaussianBlur', 'motionBlur', 'invert', 'blackWhite', 'colorBalance'},
        'LayerBlendMode': {'normal', 'darken', 'multiply', 'colorBurn', 'linearBurn', 'lighten', 'screen', 'colorDodge', 'linearDodge', 'overlay', 'softLight', 'hardLight', 'vividLight', 'linearLight', 'pinLight', 'hardMix', 'difference', 'exclusion', 'subtract', 'divide', 'hue', 'saturation', 'color', 'luminosity'},
        'FilterKind': {'gaussianBlur', 'motionBlur', 'addNoise', 'vignette', 'bloomGlow', 'dither', 'tonalContrast', 'lensCorrection', 'cameraRaw', 'removeBackground', 'contentAwareFill', 'curves', 'exposure', 'gradientMap', 'grain', 'blackWhite', 'colorBalance'},
    }.items():
        if enum_cases[typ] != required: errors.append(f'{typ}: enum coverage incomplete {sorted(required - enum_cases[typ])}')
    if MD_PATH.read_text() != markdown(data): errors.append('Markdown ledger differs from JSON')
    return errors

def carry_evidence(previous, regenerated):
    """Keep recorded results across a regeneration: copy status and execution evidence onto the regenerated row
    with the same ID. A recorded result whose row no longer exists is never dropped silently."""
    rows = {r['id']: r for r in regenerated['capabilities']}
    lost = []
    for old in previous['capabilities']:
        fixture = old.get('acceptance_fixture', {})
        if fixture.get('status') in ('planned', 'provenance_only'): continue
        new = rows.get(old['id'])
        if new is None or new['surface'] == 'implementation_support':
            lost.append(f"{old['id']} ({old['file']}:{old['line']} {old['symbol']}, {fixture.get('status')})")
            continue
        new['acceptance_fixture']['status'] = fixture['status']
        new['acceptance_fixture']['execution_evidence'] = fixture.get('execution_evidence')
    if lost:
        for row in lost[:100]: print('FAIL: recorded result would be lost for', row)
        raise SystemExit(f'{len(lost)} recorded results have no regenerated row; nothing was written')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='regenerate the inventory for review, keeping recorded results by capability ID')
    args = parser.parse_args()
    actual = build()
    if args.write:
        carry_evidence(json.loads(JSON_PATH.read_text()) if JSON_PATH.exists() else {'capabilities': []}, actual)
        JSON_PATH.write_text(json.dumps(actual, indent=2) + '\n')
        MD_PATH.write_text(markdown(actual))
    data = json.loads(JSON_PATH.read_text())
    errors = audit(data, actual)
    if errors:
        for error in errors[:100]: print('FAIL:', error)
        if len(errors) > 100: print(f'... {len(errors) - 100} additional failures')
        raise SystemExit(1)
    exposed = sum(r['surface'] != 'implementation_support' for r in data['capabilities'])
    print(f"PASS: {len(data['capabilities'])} source-surface rows ({exposed} declared controls/services with concrete planned profiles), {len(data['files'])} frozen source files, {len(data['baseline_test_cases'])} baseline test cases; support rows provenance-only.")

if __name__ == '__main__':
    main()
