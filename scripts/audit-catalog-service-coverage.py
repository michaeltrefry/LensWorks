#!/usr/bin/env python3
"""Extract/audit the retained public catalog request/result DTO graph, without GPU work."""
import argparse
import collections
import hashlib
import json
import re
import struct
import subprocess
import catalog_source
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'engines/catalog/src'
PIN = 'f4f8d3f12acc77fe5632720702c52a7cfefb5b58'
OUTPUT = ROOT / 'docs/CATALOG_SERVICE_COVERAGE.json'
MARKDOWN = ROOT / 'docs/CATALOG_SERVICE_COVERAGE.md'
BUILTINS = {'String', 'str', 'bool', 'u8', 'u16', 'u32', 'u64', 'u128', 'usize', 'i8', 'i16', 'i32', 'i64', 'i128', 'isize', 'f32', 'f64', 'Vec', 'Option', 'Box', 'BTreeMap', 'BTreeSet', 'HashMap', 'HashSet', 'Result', 'Self'}
ROOT_TYPES = ['application::dto::Request', 'application::dto::Reply', 'application::dto::Response',
              'application::Config', 'application::Limits', 'application::desktop::Config',
              'catalog_edits::VariantKey', 'storage_volume::NativePath', 'media::full::RenderedImage',
              'media::full::RenderProvenance', 'media::full::DecodeError',
              # The Workbench Rows result projects these retained SQLite cells.
              'lightroom::plan::Cell']
LEX = re.compile(r'/\*[\s\S]*?\*/|//[^\n]*|r(?P<hash>\#+)?"[\s\S]*?"(?P=hash)|"(?:\\.|[^"\\])*"')

def sha(data): return hashlib.sha256(data).hexdigest()

def masked(text):
    return LEX.sub(lambda m: ''.join('\n' if c == '\n' else ' ' for c in m.group()), text)

def layout(text):
    clean = masked(text)
    depths, pairs, stack = [0] * (len(text) + 1), {}, []
    for i, c in enumerate(clean):
        depths[i] = len(stack)
        if c in '{([': stack.append((c, i))
        elif c in '})]' and stack and {'}':'{', ')':'(', ']':'['}[c] == stack[-1][0]:
            _, begin = stack.pop(); pairs[begin] = i
    return clean, depths, pairs

def split(text, separator=','):
    clean = masked(text); levels = collections.Counter(); begin = 0; result = []
    for i, c in enumerate(clean):
        if c in '{([<': levels[c] += 1
        elif c in '})]>':
            opening = {'}':'{', ')':'(', ']':'[', '>':'<'}[c]
            levels[opening] = max(0, levels[opening] - 1)
        elif c == separator and not any(levels.values()):
            result.append((begin, text[begin:i])); begin = i + 1
    result.append((begin, text[begin:]))
    return result

def attrs(text):
    result = {'raw': []}
    for m in re.finditer(r'#\[([^\]]+)\]', text):
        attribute = m.group(1).strip(); result['raw'].append(attribute)
        if attribute.startswith('derive'):
            result['derive'] = re.findall(r'\b\w+\b', attribute)[1:]
        elif attribute.startswith('serde'):
            for key, value in re.findall(r'(\w+)\s*=\s*"([^"]*)"', attribute):
                result['default_function' if key == 'default' else key] = value
            for flag in ('default', 'flatten', 'untagged', 'deny_unknown_fields', 'skip_serializing', 'skip_deserializing'):
                if re.search(r'\b' + flag + r'\b', attribute): result[flag] = True
    return result

def strip_attributes(text):
    clean, _, pairs = layout(text)
    spans = [(m.start(), pairs[m.start() + 1] + 1) for m in re.finditer(r'#\[', clean) if m.start() + 1 in pairs]
    for start, end in reversed(spans): text = text[:start] + ' ' * (end - start) + text[end:]
    return text

def module(path):
    parts = list(path.relative_to(SOURCE).with_suffix('').parts)
    if parts[-1] in {'mod', 'lib'}: parts.pop()
    return '::'.join(parts)

def normalize(path, here):
    path = path.strip(':')
    parts = here.split('::') if here else []
    if path.startswith('crate::'): return path[7:]
    if path == 'crate': return ''
    if path.startswith('self::'): return '::'.join(parts + path[6:].split('::'))
    if path == 'self': return here
    while path.startswith('super::'):
        parts = parts[:-1]; path = path[7:]
    if path == 'super': return '::'.join(parts[:-1])
    return '::'.join(parts + path.split('::'))

def imports_for(text, here):
    result, stars = {}, []
    def walk(group, prefix=''):
        for _, item in split(group):
            item = item.strip()
            if not item: continue
            if '{' in item:
                opening = item.index('{')
                walk(item[opening + 1:item.rfind('}')], prefix + item[:opening].strip())
            else:
                raw = prefix + item
                if raw.endswith('::*'): stars.append(normalize(raw[:-3], here)); continue
                pair = re.split(r'\s+as\s+', raw)
                target = pair[0].strip()
                if target.endswith('::self'): target = target[:-6]
                alias = pair[1].strip() if len(pair) == 2 else target.split('::')[-1]
                if alias == 'self': alias = target.split('::')[-1]
                if target.startswith(('crate::', 'self::', 'super::')): target = normalize(target, here)
                elif target.startswith(('std::', 'serde::', 'serde_json::', 'anyhow::', 'uuid::', 'rusqlite::', 'lcms2::', 'image::')): pass
                else: target = normalize(target, here)
                result[alias] = target
    clean, depths, _ = layout(text)
    for m in re.finditer(r'(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?use\s+([^;]+);', clean):
        # Function, impl and inline-child-module imports have their own scope.
        # Letting them overwrite a file's module imports changes DTO authority.
        if depths[m.start(1)] == 0: walk(text[m.start(1):m.end(1)])
    return result, stars

def preceding_attributes(text, pos):
    # A declaration's own adjacent attributes. Comments are discarded; other
    # preceding item bodies/semicolons terminate the search.
    before = text[max(0, pos - 2400):pos]
    clean = masked(before)
    stop = max(clean.rfind('}'), clean.rfind(';'))
    return attrs(before[stop + 1:])

def fields(body, base, text, positional=False):
    result = []
    for index, (offset, chunk) in enumerate(split(body)):
        if not masked(chunk).strip(): continue
        stripped = strip_attributes(chunk)
        clean = masked(stripped)
        declaration = re.sub(r'^\s*pub(?:\([^)]*\))?\s+', '', clean).strip()
        metadata = attrs(chunk)
        if positional:
            name, typ = str(index), declaration
        else:
            match = re.match(r'([A-Za-z_]\w*)\s*:\s*(.+)', declaration, re.S)
            if not match: continue
            name, typ = match.groups()
        pos = base + offset
        result.append({'name': name, 'rust_type': re.sub(r'\s+', ' ', typ).strip(), 'serde': metadata,
                       'line': text.count('\n', 0, pos) + 1})
    return result

def parse_sources():
    nodes, modules, files = {}, {}, []
    for path in sorted(SOURCE.rglob('*.rs')):
        if '/tests/' in str(path) or '_tests.rs' in path.name or path.name == 'tests.rs': continue
        text = path.read_text(); clean, depths, pairs = layout(text); here = module(path)
        imported, stars = imports_for(text, here); modules[here] = {'imports': imported, 'stars': stars}
        rel = str(path.relative_to(ROOT)); files.append({'file': rel, 'sha256': sha(path.read_bytes())})
        for m in re.finditer(r'(?m)^\s*(?P<visibility>pub(?:\([^)]*\))?\s+)?(?P<kind>enum|struct|type)\s+(?P<name>[A-Za-z_]\w*)', clean):
            if depths[m.start('kind')] != 0: continue
            name, kind = m.group('name'), m.group('kind')
            after = m.end()
            candidate = re.search(r'[;{(]', clean[after:])
            if not candidate: continue
            opening = after + candidate.start()
            node = {'id': '::'.join(filter(None, (here, name))), 'module': here, 'name': name, 'kind': kind,
                    'file': rel, 'line': text.count('\n', 0, m.start('kind')) + 1,
                    'visibility': (m.group('visibility') or '').strip(), 'serde': preceding_attributes(text, m.start('kind')),
                    'fields': [], 'variants': []}
            header = text[after:opening]
            generic = re.search(r'<([^>]+)>', header)
            node['generic_parameters'] = [piece.split(':')[0].strip() for piece in generic.group(1).split(',')] if generic else []
            if kind == 'type':
                end = clean.find(';', after); alias = text[after:end].strip()
                node['alias_type'] = alias[alias.find('=') + 1:].strip()
            elif clean[opening] == ';': pass
            elif opening in pairs:
                closing = pairs[opening]; body = text[opening + 1:closing]
                if kind == 'struct':
                    node['struct_shape'] = 'tuple' if clean[opening] == '(' else 'named'
                    node['fields'] = fields(body, opening + 1, text, clean[opening] == '(')
                else:
                    for offset, chunk in split(body):
                        noattrs = strip_attributes(chunk); stripped = masked(noattrs)
                        match = re.match(r'\s*([A-Za-z_]\w*)', stripped)
                        if not match: continue
                        variant = {'name': match.group(1), 'line': text.count('\n', 0, opening + 1 + offset + match.start(1)) + 1,
                                   'serde': attrs(chunk[:match.start(1)]), 'shape': 'unit', 'fields': []}
                        remainder = stripped[match.end():]
                        payload = re.search(r'[{(]', remainder)
                        if payload:
                            start = match.end() + payload.start(); _, _, chunk_pairs = layout(chunk)
                            if start in chunk_pairs:
                                end = chunk_pairs[start]; variant['shape'] = 'tuple' if stripped[start] == '(' else 'struct'
                                variant['fields'] = fields(chunk[start + 1:end], opening + 1 + offset + start + 1, text, variant['shape'] == 'tuple')
                        node['variants'].append(variant)
            nodes[node['id']] = node
        # Source-expanded Lightroom wire limits are actual macro-generated DTOs.
        for m in re.finditer(r'(?m)^limits!\(\s*(\w+)\s*,\s*([^,]+),\s*\[([^\]]+)\]\s*\);', text):
            name = m.group(1); identity = here + '::' + name
            nodes[identity] = {'id': identity, 'module': here, 'name': name, 'kind': 'struct', 'struct_shape': 'named',
                               'file': rel, 'line': text.count('\n', 0, m.start()) + 1, 'visibility': 'pub',
                               'serde': {'derive': ['Clone', 'Debug', 'Serialize', 'Deserialize'], 'deny_unknown_fields': True, 'raw': ['macro limits! expands pub field: U64']},
                               'generic_parameters': [], 'macro_expansion': 'limits!', 'core_type': m.group(2).strip(),
                               'fields': [{'name': field.strip(), 'rust_type': 'U64', 'serde': {'raw': []}, 'line': text.count('\n', 0, m.start()) + 1} for field in m.group(3).split(',') if field.strip()], 'variants': []}
    # Macro-generated lossless numeric wrappers are actual public wire types.
    for path in sorted(SOURCE.rglob('*.rs')):
        if module(path) not in modules: continue
        text = path.read_text()
        for m in re.finditer(r'(?m)^decimal!\((\w+),\s*(\w+)\);', text):
            here = module(path); name, primitive = m.groups(); identity = here + '::' + name
            nodes[identity] = {'id': identity, 'module': here, 'name': name, 'kind': 'decimal_string',
                               'file': str(path.relative_to(ROOT)), 'line': text.count('\n', 0, m.start()) + 1,
                               'visibility': 'pub', 'serde': {'wire': 'canonical_decimal_string'}, 'fields': [], 'variants': [], 'rust_primitive': primitive}
    # This exported numeric wrapper has handwritten serde implementations.
    custom = nodes['application::exports::dto::U128']
    custom.update(kind='decimal_string', rust_primitive='u128', fields=[], serde={'wire': 'canonical_decimal_string', 'raw': ['impl Serialize + Deserialize validates u128.to_string()']})
    return nodes, modules, files

def resolver(nodes, modules):
    def resolve(name, here, seen=None):
        seen = set() if seen is None else seen
        key = (name, here)
        if key in seen: return None
        seen.add(key)
        if name in BUILTINS or name.startswith(('std::', 'serde_json::', 'anyhow::', 'image::', 'lcms2::')): return None
        if name.startswith(('crate::', 'self::', 'super::')):
            target = normalize(name, here)
            return resolve_qualified(target, seen)
        first, *rest = name.split('::')
        data = modules.get(here, {})
        target = '::'.join(filter(None, (here, name)))
        if target in nodes: return target
        if first in data.get('imports', {}):
            target = data['imports'][first] + ('::' + '::'.join(rest) if rest else '')
            found = resolve_qualified(target, seen)
            if found: return found
        found = resolve_qualified(target, seen)
        if found: return found
        candidates = set()
        for star in data.get('stars', []):
            found = resolve_qualified(star + '::' + name, set(seen))
            if found: candidates.add(found)
        if len(candidates) > 1: raise ValueError(f'ambiguous wildcard type {here}::{name}: {sorted(candidates)}')
        return next(iter(candidates), None)
    def resolve_qualified(target, seen):
        if target in nodes: return target
        key = ('qualified', target)
        if key in seen: return None
        seen.add(key)
        if '::' not in target: return None
        parent, name = target.rsplit('::', 1)
        data = modules.get(parent, {})
        if name in data.get('imports', {}):
            next_target = data['imports'][name]
            if next_target != target: return resolve_qualified(next_target, seen)
        candidates = set()
        for star in data.get('stars', []):
            candidate = star + '::' + name
            found = resolve_qualified(candidate, set(seen))
            if found: candidates.add(found)
        if len(candidates) > 1: raise ValueError(f'ambiguous wildcard type {target}: {sorted(candidates)}')
        if candidates: return next(iter(candidates))
        # Qualified paths can start with a module alias (e.g. lw::OpenMode).
        parts = target.split('::')
        for length in range(len(parts) - 1, 0, -1):
            scope = '::'.join(parts[:length - 1]); alias = parts[length - 1]
            import_target = modules.get(scope, {}).get('imports', {}).get(alias)
            if import_target:
                remapped = import_target + '::' + '::'.join(parts[length:])
                if remapped != target: return resolve_qualified(remapped, seen)
        return None
    return resolve

def type_tokens(typ):
    return [m.group() for m in re.finditer(r'\b[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*', typ)
            if m.group() not in BUILTINS and not m.group().startswith(('std::', 'serde_json::', 'anyhow::', 'image::', 'lcms2::'))]

def graph():
    nodes, modules, files = parse_sources(); resolve = resolver(nodes, modules)
    roots, missing_roots = [], []
    for requested in ROOT_TYPES:
        found = requested if requested in nodes else resolve(requested, '')
        if found: roots.append(found)
        else: missing_roots.append(requested)
    queue, visited, unresolved = list(roots), {}, []
    while queue:
        identity = queue.pop(0)
        if identity in visited: continue
        node = json.loads(json.dumps(nodes[identity])); visited[identity] = node
        # Test-only imports are source evidence, not runtime DTO fields.
        node['fields'] = [field for field in node['fields'] if not any(re.search(r'cfg\(\s*test\s*\)', a) for a in field['serde'].get('raw', []))]
        node['wire_serializable'] = ('Serialize' in node['serde'].get('derive', []) or node['kind'] == 'decimal_string')
        node['role'] = 'wire_dto' if node['wire_serializable'] else ('runtime_configuration' if node['name'] == 'Config' else 'public_core_seam')
        all_fields = node['fields'] + [field for variant in node['variants'] for field in variant['fields']]
        if node.get('alias_type'): all_fields.append({'name': '<alias>', 'rust_type': node['alias_type']})
        for field in all_fields:
            references = []
            field['generic_parameter_refs'] = []
            for token in type_tokens(field['rust_type']):
                if token in node.get('generic_parameters', []):
                    field['generic_parameter_refs'].append(token); continue
                found = resolve(token, node['module'])
                if found:
                    references.append({'rust_token': token, 'type_id': found}); queue.append(found)
                elif token not in {'T', 'E', 'P', 'a', 'de', 'PhantomData', 'AtomicBool', 'PathBuf', 'Duration', 'Arc', 'Mutex', 'Uuid'}:
                    unresolved.append({'owner': identity, 'field': field['name'], 'token': token, 'rust_type': field['rust_type']})
            field['type_refs'] = references
    used_files = {node['file'] for node in visited.values()}
    return {'schema_version': 1, 'story_id': 'sc-24658', 'baseline': {'revision': PIN, 'source': 'engines/catalog', 'source_digest': catalog_source.verify()},
            'root_type_ids': roots, 'missing_roots': missing_roots,
            'types': list(sorted(visited.values(), key=lambda node: node['id'])),
            'source_files': [item for item in files if item['file'] in used_files],
            'unresolved_type_references': unresolved,
            'status': 'source_extracted_not_native_acceptance', 'capabilities': [], 'fixture_profiles': {}, 'execution_evidence': []}

# Each mapping is reviewed against the frozen actor/coordinator branches. These
# are result types, not claims that their successful workflow has been exercised.
RESULTS = {
 'application::dto::Request': {
  'PreviewSettings':['PreviewSettings'], 'LightroomMigration':['LightroomMigration'], 'Lightroom':['Lightroom'], 'Export':['Export'], 'EditCopy':['EditCopy'], 'Relink':['Relink'],
  'OpenExisting':['Status'], 'Create':['Status'], 'Status':['Status'], 'Close':['Status'],
  'ImportStart':['Import'], 'ImportResume':['Import'], 'ImportStatus':['Import'], 'ImportCancel':['Import'],
  'BackupCreate':['Backup'], 'BackupInspect':['Backup'], 'BackupRestore':['Backup'], 'BackupStatus':['Backup'], 'BackupCancel':['Backup'], 'RestoreStatus':['Restore'], 'ResumeRestoredJobs':['Restore'],
  'Metadata':['Metadata'], 'MetadataWrite':['MetadataWrite'], 'Organization':['Organization'], 'Folders':['Folders'], 'Images':['Images'], 'Search':['Images'], 'SearchAmong':['Images'], 'Image':['Image'],
  'Variant':['Variant'], 'Variants':['Variants'], 'CreateVariant':['Variant'], 'SaveRecipe':['Variant'], 'Undo':['Variant'], 'Redo':['Variant'], 'History':['History'], 'Cull':['Culled'],
  'Preview':['Preview'], 'PreviewStatus':['Preview'], 'ReleaseViewport':['Status'], 'CancelPreview':['Preview']},
 'application::metadata::Request': {**{x:[x] for x in ['Identity','Fields','Candidates','Sources','Observations','Models','Packets','Decisions','FileInstances','ImportHistory','ImportColumns','ImportFields','AdobeProperties']}, 'Resolve':['Changed'],'TextChunk':['Chunk'],'BlobChunk':['Chunk'],'ImportChunk':['Chunk']},
 'application::metadata_write::Request': {'Options':['Options'],'Status':['Status'],'Cancel':['Status'],'Start':['Admitted'],'InputStatus':['Input'],'Receipt':['Receipt'],'Review':['Review'],'ReviewFields':['ReviewFields'],'Chunk':['Chunk'],'Plans':['Plans'],'Plan':['Plan'],'RecoveryEntries':['RecoveryEntries']},
 'application::organization::Request': {'Keywords':['Keywords'],'CreateKeyword':['KeywordCreated'],'DeleteKeyword':['Acknowledged'],'FindKeyword':['Keyword'],'Synonyms':['Synonyms'],'AddSynonym':['Acknowledged'],'RemoveSynonym':['Acknowledged'],'Collections':['Collections'],'Collection':['Collection'],'CreateCollection':['CollectionCreated'],'RenameCollection':['Acknowledged'],'DeleteCollection':['Acknowledged'],'Placement':['Placement'],'PlaceCollection':['Acknowledged'],'Members':['Members'],'Identity':['Identity'],'States':['States'],'SetMember':['Changed'],'Apply':['Changed'],**{x:['Job'] for x in ['Begin','Append','Seal','Step','Run','Cancel','Job','Review']},'Jobs':['Jobs'],'Items':['Items']},
 'application::relink::Request': {'Rules':['Rules'],'Begin':['Plan'],'Prepare':['Operation'],'Revise':['Operation'],'Plan':['Plan'],'Plans':['Plans'],'Items':['Items'],'Sources':['Sources'],'Confirm':['Operation'],'Apply':['Operation'],'Undo':['Operation'],'Mounts':['Operation'],'Original':['Operation'],'Status':['Operation'],'Cancel':['Operation']},
 'application::copy::Request': {'Begin':['Job'],'Append':['Job'],'Seal':['Job'],'Run':['Operation'],'Status':['Operation'],'Cancel':['Operation','Job'],'Job':['Job'],'Jobs':['Jobs'],'Items':['Items'],'Inspect':['Inspection']},
 'application::preview_settings::Request': {x:['Status'] for x in ['Status','SetBudgets','BeginOriginalRootReview','StepOriginalRootReview','BeginRelocation','StepRelocation']},
 'application::lightroom_migration::Request': {**{x:['Status'] for x in ['Begin','Upload','Finish','Act','Status','Cancel','RetryDrain']},'Cancel':['Status','Discarded'],'ResultPage':['Page'],'Discard':['Discarded']},
 'application::lightroom_bridge::wire::Request': {'SealedDocument':['SealedDocument'],'ArtifactPreparation':['ArtifactPreparation'],'Options':['Options'],**{x:['Status'] for x in ['Open','Status','Action','Read','Cancel','Close']},'Result':['Result'],**{x:['Input'] for x in ['InputBegin','InputAppend','InputFinish','InputDiscard','InputStatus']}},
 'application::exports::dto::Request': {'Options':['Options'],'Profile':['Operation'],'ProfileRelease':['Released'],'Begin':['Job'],'Paths':['Operation'],'Destinations':['Operation'],'DestinationRows':['Destinations'],'ResultRelease':['Released'],'Append':['Operation'],'Seal':['Job'],'Job':['Job'],'Jobs':['Jobs'],'Items':['Items'],'Plan':['Plan'],'PlanChunk':['PlanChunk'],'Run':['Operation'],'Status':['Operation'],'Cancel':['Operation','Job'],'Yield':['Operation'],'Recover':['Operation'],'RetrySeal':['Operation'],'Restore':['Operation']}
}
FAMILIES = {
 'metadata': ('metadata-resolution', ['Retain fixture.png with two XMP title candidates: Camera and Chosen; collect the real VariantKey and metadata revision.', 'Read Identity, paged Fields/Candidates/Sources/Observations/Models/Packets/Decisions/FileInstances and all text/blob/import chunks with page limit 2 and chunk length 16.', 'Resolve the title to Chosen at the recorded revision; repeat with the stale revision.'], ['Changed.revision advances; Fields resolves title Chosen and both candidates remain auditable.', 'Paged/chunk replies preserve offsets, exact bytes and next cursors; stale Resolve cannot change any stored decision.'], ['Use a foreign catalog token: Reply::Error StaleSession.', 'Use page limit 0: InvalidRequest; request bytes over configured cap: ResourceLimit.']),
 'metadata_write': ('metadata-write-recovery', ['Use fixture.png plus fixture.png.xmp containing title Before; record both original hashes.', 'Read Options; Start with InputBegin, append exact UTF8 edit document bytes, InputFinish, Prepare/Review and Commit, then SidecarPlan and SidecarApply using returned token/generation/review digest and attempt.', 'Read InputStatus/Receipt/ReviewFields/Chunk/Plans/Plan/RecoveryEntries; cancel one admitted write and restart the managed session.'], ['Review title After before publication; Receipt identifies the exact operation and target.', 'Source image hash stays equal; successful sidecar write publishes After once; restart preserves plan/recovery evidence.'], ['Reject stale token/generation/review digest and wrong epoch; no overwrite from a stale review.', 'Interrupted publication retains recovery evidence instead of reporting successful rollback.']),
 'organization': ('organization-revisions', ['Import fixture-a.png and fixture-b.png; create flat keyword LensWorks, hierarchical keyword Travel/Paris, synonym LW and collection Picks.', 'Apply rating4, Pick flag, Blue label, add/remove/move keywords and collection member edits using current per-image revision.', 'Begin batch; Append both identities; Seal; Step to completion; read Jobs/Items and Review; exercise Cancel on a second batch.'], ['Queries return the created exact keyword path, synonym and collection placement.', 'Changed revision advances for each accepted edit; Members contains the intended identities, and batch terminal counts equal two targets.'], ['Stale image revision rejects the edit without changing rating/member rows.', 'Collection placement cycle and deleting an in-use keyword fail; current rows remain unchanged.']),
 'relink': ('relink-review-identity', ['Import fixture-a.png at root-A, record source hashes; copy exact bytes to root-B, then move root-A aside.', 'Read Rules; Begin with asset scope; Prepare root-B; page Plans/Items/Sources; revise or Confirm with the returned plan revision.', 'Apply, poll Status, query Original/Mounts, then Undo; Cancel an independently preparing plan.'], ['Review identifies matching fingerprints and the chosen lossless NativePath.', 'Apply changes catalog locators only; Undo restores prior locator authority; both original copies keep their hashes.'], ['Changed candidate bytes or stale plan revision prevents Apply.', 'Ambiguous candidates remain unresolved until explicit review; cancellation preserves the previous mapping.']),
 'copy': ('adjustment-transfer', ['Import two images and save source exposure1.25/contrast0.2; target exposure-0.5/contrast-0.1.', 'Begin selecting only Exposure; Append target at real expected revision; Seal with exact total; Inspect and Run; read Jobs/Items.', 'Cancel a second queued job and reopen catalog to inspect persistent job.'], ['Target exposure becomes1.25 and contrast remains-0.1; target edit revision advances once.', 'Inspection digest binds the source recipe and selected groups; terminal item counts reflect applied/skipped/conflicted outcomes.'], ['Mutate target recipe after Append; Run reports conflict and preserves newer target.', 'Active cancellation requires the matching operation id; no overwrite of newer edits.']),
 'preview_settings': ('preview-policy-relocation', ['Read Status and SetBudgets with explicit nonzero proxy/thumbnail budgets from Options-compatible bounds.', 'BeginOriginalRootReview with source root, step exact returned review token with directories2 to completion.', 'BeginRelocation for thumbnail then large tier to empty cache-B; step tier with objects2 and explicit byte allowance and poll Status; restart.'], ['Status reflects supplied budgets and original-root review progress.', 'Completed relocation changes the selected tier root; retained items remain discoverable and originals stay outside cache roots.'], ['Overlapping original/cache roots reject admission.', 'Stale original-root review token or changed storage epoch cannot validate another mapping; StepRelocation selects exact tier.']),
 'lightroom_migration': ('guarded-migration', ['Create a tiny closed Lightroom SQLite fixture and use retained worker fixture documents for every Operation/InputRole.', 'Begin with exact PartDescriptor byte lengths/digests; Upload ordered UTF8 fragments; Finish each role with computed BLAKE3; Act; poll Status and ResultPage.', 'Cancel before completion, RetryDrain when required, and Discard only the matching returned Guard; restart and review persisted destination.'], ['Exact Guard/generation remains attached to progress and result pages; uploaded byte totals match documents.', 'Migration result identities and catalogs preserve supported metadata, collections, history and provenance from the declared documents.'], ['Wrong offset, byte total, digest, role, operation or Guard fails before migration authority is admitted.', 'Cancel with uncertain drain reports DrainPending; no false successful close/discard.']),
 'lightroom_bridge': ('workbench-input-review', ['Use read-only Workbench on a tiny closed Lightroom SQLite fixture; Open returns real workbench/generation; read Options and Status.', 'Exercise every Action and Query with the required returned revision/evidence; upload Inventory, SelectionRequest, Approval and ApprovalDraft via InputBegin/Append/Finish.', 'Read Result/SealedDocument/ArtifactPreparation using real tokens and digest approvals; InputDiscard, Cancel and Close; retain source hash.'], ['Queries return bounded rows/chunks under exact selected revision; flattened ResultPage roundtrips without a page key.', 'PrepareSelection/Seal require matching review token and approval digest; closed source catalog bytes remain identical.'], ['Stale workbench/generation/evidence or wrong input offset rejects the action.', 'Open read-only never writes source SQLite; Cancel/Close drains before releasing authority.']),
 'exports': ('export-staging-recovery', ['Import a tiny RGBA float-capable fixture, record original BLAKE3; read Options, admit an ICC Profile and release it after use.', 'Begin; resolve Paths/Destinations/DestinationRows; Append a target with exact revision and explicit OutputSize/OutputFormat/Profile/AlphaPolicy/Metadata; Seal exact total.', 'Run with explicit limits; read Job/Jobs/Items/Plan/PlanChunk/Status; Yield/Cancel a second operation; Recover/RetrySeal/Restore from real recovery authority; release result token.'], ['Retained exports support PNG8/16, JPEG8 with explicit alpha handling and TIFF8/16/float32; export routes never imply PSD/PSB export.', 'Published receipt binds source fingerprint, recipe/metadata digest, original identity and reviewed destination; reopen retains jobs/items and source hash is identical.'], ['Stale plan authority/source fingerprint or changed destination blocks publication.', 'Existing output is preserved when overwrite=false; truncated staged output is recoverable and is never reported complete.']),
 'catalog': ('catalog-open-close', ['Create an empty catalog beneath a temporary root; read real Status.catalog token; Close and OpenExisting same root.', 'Query Status from an independent job while another request is pending; release all returned owned buffers and jobs.', 'Close twice according to retained session semantics and drain worker before final handle release.'], ['Status returns a usable catalog token; reopen preserves schema/version and catalog identity.', 'Transport reaches verified Closed after child/process/callback drain; every owned handle has one release.'], ['Open missing path fails without creating it.', 'Wrong catalog token returns StaleSession; request after shutdown reports Closed.']),
 'import': ('import-resume', ['Create source root with exactly two tiny PNGs plus an unsupported text file and record every file hash.', 'Create catalog; ImportStart; poll ImportStatus; cancel one run via returned import id; reopen and ImportResume the same source.', 'Repeat resume after completion; list Images/Folders.'], ['Exactly two physical assets are retained; unchanged second resume adds no duplicate image identity.', 'Terminal counters distinguish imported/unchanged/failed/skipped/pending previews; all source hashes are unchanged.'], ['Relative source path is InvalidRequest.', 'Overlapping import is Busy; wrong import id cannot cancel another operation.']),
 'backup': ('backup-restore-held-jobs', ['Create catalog with two images and one pending organization/export job; record source and catalog identity.', 'BackupCreate into new bundle; poll BackupStatus; BackupInspect verifies actual receipt; BackupRestore into new destination; open restored destination.', 'RestoreStatus reports held jobs; ResumeRestoredJobs supplies actual restore_id and explicit acknowledgement; cancel a separate backup.'], ['Backup receipt identifies schema/application/database bytes and BLAKE3; restored images and metadata counts match two.', 'Restored pending jobs stay held until explicit matching acknowledgement; backup includes catalog state, not a relocated original copy.'], ['Wrong restore_id fails; refusal to acknowledge pending jobs leaves jobs held.', 'Existing restore destination or altered bundle digest fails without replacing existing catalog.']),
 'browse': ('browse-edit-history', ['Import two fixture images with different ratings/names; Images/Folders paginate with limit1 and returned cursors.', 'Search each nondefault filter and Sort/Direction against known metadata; Image/Variants retain exact master/variant keys.', 'CreateVariant; SaveRecipe exposure1.25 at current revision; Undo; Redo; History; Cull rating4/Blue/Pick using real metadata revision.'], ['Pages retain both identities exactly once; each filter returns the fixture with matching stored value.', 'Save/Undo/Redo bind recipe digests and advance revision; history persists across close/reopen; master original bytes never change.'], ['Search rating6 or limit0 is InvalidRequest.', 'Stale edit/metadata revision cannot overwrite a newer recipe or cull.']),
 'preview': ('preview-generation-bytes', ['Import fixture.png; request thumbnail then proxy with viewport main and increasing generations; poll PreviewStatus.', 'Copy admitted preview bytes into owned buffer; release viewport and cancel the matching ticket; reopen offline original root after retained preview exists.', 'Change exposure and request newer generation; drain old generation deliveries.'], ['Bytes are routed to exact ticket/key/revision/recipe digest; late prior-generation result cannot replace current preview.', 'Offline retained preview remains available with explicit unavailable-original state; browse preview is never accepted as full precision editor input.'], ['Expired/unknown ticket gives StaleSession.', 'Canceled or superseded viewport request cannot deliver current-generation authority.'])
}

def wire_name(name, metadata):
    if metadata.get('rename'): return metadata['rename']
    rule = metadata.get('rename_all')
    if rule == 'snake_case': return re.sub(r'(?<!^)(?=[A-Z][a-z])|(?<=[a-z0-9])(?=[A-Z])', '_', name).lower()
    if rule == 'lowercase': return name.lower()
    return name

def reachable(nodes, root):
    paths, queue = {root: []}, [root]
    while queue:
        identity = queue.pop(0); node = nodes[identity]
        entries = [(None, field) for field in node['fields']] + [(v['name'], field) for v in node['variants'] for field in v['fields']]
        for variant, field in entries:
            for ref in field.get('type_refs', []):
                target = ref['type_id']
                if target not in paths:
                    paths[target] = paths[identity] + [{'type_id':identity,'variant':variant,'field':field['name'],'target_type_id':target}]
                    queue.append(target)
    return paths

def fixture_family(identity, path, variant=None):
    for family in ['metadata_write','metadata','organization','preview_settings','relink','copy','lightroom_migration','lightroom_bridge','exports']:
        if ('::' + family + '::') in identity or any(('::' + family + '::') in edge['type_id'] for edge in path): return family
    top = path[0]['variant'] if path else variant
    top_family={'PreviewSettings':'preview_settings','LightroomMigration':'lightroom_migration','Lightroom':'lightroom_bridge','Export':'exports','EditCopy':'copy','Relink':'relink','Metadata':'metadata','MetadataWrite':'metadata_write','Organization':'organization'}
    if top in top_family: return top_family[top]
    if top and top.startswith('Import'): return 'import'
    if top and (top.startswith('Backup') or top in {'RestoreStatus','ResumeRestoredJobs'}): return 'backup'
    if top and top in {'Preview','PreviewStatus','CancelPreview','ReleaseViewport'}: return 'preview'
    if top and top not in {'Create','OpenExisting','Status','Close'}: return 'browse'
    return 'catalog'

def wire_sample(nodes, identity, selections=None, stack=None, bindings=None, populated=False):
    selections, stack = selections or {}, stack or []
    bindings = bindings or {}
    if identity in stack: raise ValueError('recursive request DTO: ' + identity)
    node = nodes[identity]; stack = stack + [identity]
    if node['kind'] == 'decimal_string': return '1'
    if identity == 'storage_volume::NativePath' and selections.get(identity,'UnixBytes') == 'UnixBytes': return {'encoding':'UnixBytes','units':list(b'/tmp/lensworks-fixture/source/fixture.png')}
    if identity == 'catalog_edits::VariantKey': return {'asset_id':'00000000-0000-4000-8000-000000000001','variant_id':'master'}
    def exact_references(typ, field):
        found=[]
        for token in type_tokens(typ):
            if token in bindings:
                bound=bindings[token];found.extend(exact_references(bound['rust_type'],bound))
            else:found.extend(r['type_id'] for r in field.get('type_refs',[]) if r['rust_token']==token)
        return found
    def value(field):
        typ = field['rust_type']; name = field['name']
        if typ in bindings: return value({**bindings[typ], 'name': name})
        if field.get('serde',{}).get('with') == 'hex_bytes': return '00ff80'
        references = [r['type_id'] for r in field.get('type_refs',[])]
        selected_descendant = any(target in selections or any(x in selections for x in reachable(nodes,target)) for target in references)
        generic = re.fullmatch(r'([\w:]+)\s*<(.+)>', typ)
        if generic:
            container, arguments = generic.groups()
            arguments = [piece.strip() for _, piece in split(arguments)]
            if container == 'Option':
                if not selected_descendant and not populated: return None
                if any(target in stack for target in exact_references(arguments[0],field)): return None
                return value({**field, 'rust_type': arguments[0]})
            if container == 'Box': return value({**field, 'rust_type': arguments[0]})
            if container in {'Vec','BTreeSet','HashSet'}:
                if populated or selected_descendant: return [value({**field, 'rust_type': arguments[0]})]
                if name in {'path','parts'} and typ == 'Vec<String>': return ['LensWorks']
                return []
            if container in {'BTreeMap','HashMap'}:
                return {str(value({**field,'rust_type':arguments[0]})):value({**field,'rust_type':arguments[1]})} if populated else {}
            ref = next((r['type_id'] for r in field.get('type_refs',[]) if r['rust_token'] == container), None)
            if ref:
                parameters = nodes[ref].get('generic_parameters',[])
                if len(parameters) != len(arguments): raise ValueError(f'generic arity mismatch {identity}.{name}: {typ}')
                arguments = [{**bindings.get(arg,field),'rust_type':bindings.get(arg,{}).get('rust_type',arg)} for arg in arguments]
                return wire_sample(nodes,ref,selections,stack,dict(zip(parameters,arguments)),populated)
        if typ.startswith('(') and typ.endswith(')'):
            return [value({**field, 'rust_type': member.strip()})
                    for _, member in split(typ[1:-1]) if member.strip()]
        ref = next((r['type_id'] for r in field.get('type_refs',[]) if r['rust_token']==typ), None)
        if ref: return wire_sample(nodes,ref,selections,stack,bindings,populated)
        if typ == 'bool': return name in {'foreground','acknowledge_pending_jobs','present'}
        if typ in {'f32','f64'}:
            number={'right':0.9,'bottom':0.9,'left':0.1,'top':0.1,'radius_px':1.0,'exposure_ev':1.25,'tint':0.0,'kelvin':6500.0}.get(name,0.0)
            # serde_json::to_value widens the actual binary32 value to f64.
            # Expected JSON must retain those bits as well as float token kind.
            return struct.unpack('<f',struct.pack('<f',number))[0] if typ=='f32' else number
        if re.fullmatch(r'[ui]\d+|usize|isize',typ): return {'after':0,'offset':0,'kelvin':6500,'value':4,'limit':2,'length':16,'width':2,'height':2}.get(name,1)
        if typ == 'String' or typ in {'&str',"&'a str"}:
            if any(x in name for x in ['digest','blake3','fingerprint','authority','expected_evidence']): return 'a'*64
            return {'catalog':'fixture-session','label':'Blue','name':'Picks','synonym':'LW','viewport':'main','text':'After','fragment':'{}','operation':'00000000-0000-4000-8000-000000000002','attempt':'00000000-0000-4000-8000-000000000003','job':'00000000-0000-4000-8000-000000000004','reason':'fixture review','variant_id':'master'}.get(name,'fixture-'+name)
        if typ.startswith('['):
            inner,count = typ.strip('[]').split(';'); return [0.0 if inner.strip() in {'f32','f64'} else 0]*int(count)
        if typ.startswith('serde_json::Value'): return {}
        raise ValueError(f'no wire specimen for {identity}.{name}: {typ}')
    def payload(fields, shape):
        values = [value(f) for f in fields]
        if shape == 'unit': return None
        if shape == 'tuple': return values[0] if len(values)==1 else values
        result = {}
        for f,v in zip(fields,values):
            if v is None and f.get('serde',{}).get('skip_serializing_if') == 'Option::is_none': continue
            if f.get('serde',{}).get('flatten'): result.update(v)
            else: result[wire_name(f['name'],f.get('serde',{}))] = v
        return result
    if node['kind'] == 'struct': return payload(node['fields'],node.get('struct_shape','named'))
    if node['kind'] == 'enum':
        variant = next((v for v in node['variants'] if v['name']==selections.get(identity)),node['variants'][0])
        name = wire_name(variant['name'],{**node['serde'],**variant['serde']}); body = payload(variant['fields'],variant['shape']); serde=node['serde']
        if serde.get('untagged'): return body
        if serde.get('tag'):
            result={serde['tag']:name}
            if serde.get('content'):
                if variant['shape']!='unit': result[serde['content']]=body
            elif variant['shape']!='unit':
                if not isinstance(body,dict): raise ValueError('internal tag scalar payload '+identity)
                result.update(body)
            return result
        return name if variant['shape']=='unit' else {name:body}
    raise ValueError('unknown input type '+identity)

CORE_SEAMS = [
 ('source-render-identity','catalog_edits.rs','edit_render_identity','source-identity', ['Query VariantKey::master(real asset); bind physical_generation, fingerprint, image identity, edit revision and recipe digest.', 'Save exposure1.25 and compare identity before/after; same original fingerprint but new edit revision/digest.', 'Attempt with_edit_identity using stale identity: callback not invoked, result None.']),
 ('logical-image-identity','catalog_images.rs','image_metadata_identity','source-identity',['Query master and created variant separately; metadata edits advance only the applicable image revision.', 'Source observation change advances shared source epoch/physical generation; source hash remains original.']),
 ('verified-original-f32','edit/render.rs','decode_original','full-float-original',['Decode tiny float TIFF with pixels[-0.25,0.5012345,1.25,1.0] under actual expected BLAKE3 and WhiteBalance::AsShot.', 'Assert f32 linear channels retain negative/high values and >8bit fractional precision; exact=true and original dimensions2x2.', 'Wrong fingerprint fails SourceChanged; source file bytes remain unchanged.']),
 ('full-original-decode','media/full.rs','decode_full_limited','full-float-original',['Decode actual PNG/TIFF fixture under finite DecodeLimits; preserve orientation/color/provenance.', 'Exceed encoded/pixel/allocation limits and assert typed ResourceLimit rather than unbounded allocation.']),
 ('full-recipe-render','edit/render.rs','render_recipe','full-float-original',['Apply validated exposure+1EV to linear[0.25,0.125,0.5,1] original input; expected RGB doubles before output clipping.', 'RenderPurpose::ExportExact must reject proxy-only input; cancellation cannot publish partial current output.']),
 ('staged-photo-render','photo_render.rs','render_staged_photo','full-float-original',['Render verified original to caller-owned fresh stage with PNG/JPEG/TIFF OutputSpec and explicit alpha policy.', 'Compare original BLAKE3 before/after and receipt source_fingerprint, recipe_digest, renderer identity.', 'Changed source/occupied stage/cancel fails without publishing destination.'])
]

BASELINE_TEST_FILES = {
 'metadata':['application/metadata_tests.rs','application/metadata_bridge_tests.rs'],
 'metadata_write':['application/metadata_write.rs'], 'organization':['application/organization.rs'],
 'relink':['application/relink/tests.rs'], 'copy':['application/copy/tests.rs'],
 'preview_settings':['application/preview_settings.rs'],
 'lightroom_migration':['application/desktop/migration/tests.rs','application/desktop/lightroom_migration/tests.rs'],
 'lightroom_bridge':['application/lightroom_bridge/tests.rs','application/desktop/workbench_capability_tests.rs'],
 'exports':['application/exports/tests.rs','application/desktop/export_native/tests.rs'],
 'catalog':['application/desktop/tests.rs','application/tests.rs'],
 'import':['application/tests.rs'], 'backup':['application/desktop/tests.rs','application/backup.rs'],
 'browse':['application/tests.rs'], 'preview':['application/preview_delivery/tests.rs','application/tests.rs'],
 'public_core':['edit/render.rs','photo_render.rs','media/raw_highlight_tests.rs']
}

def baseline_test_evidence(family):
    evidence=[]
    for filename in BASELINE_TEST_FILES.get(family,[]):
        path=SOURCE/filename;text=path.read_text()
        for match in re.finditer(r'#\[test\]\s*(?:#\[[^\]]*\]\s*)*fn\s+(\w+)',text):
            evidence.append({'file':str(path.relative_to(ROOT)), 'line':text.count('\n',0,match.start())+1,'symbol':match.group(1),'status':'source_discovered_not_executed_here'})
    return evidence

def enrich(data):
    nodes={node['id']:node for node in data['types']}; paths=reachable(nodes,'application::dto::Request'); caps=[]; profiles={}
    for family,(name,steps,observables,faults) in FAMILIES.items():
        profiles[name]={'id':name,'family':family,'status':'planned_unrun','setup':'Temporary catalog/source/cache roots only; real returned identities/tokens and bounded worker.','actions':steps,'observables':observables,'faults':faults,'source_revision':catalog_source.verify(), 'upstream_revision':PIN,'baseline_test_evidence':baseline_test_evidence(family)}
    profiles['source-identity']={'id':'source-identity','family':'public_core','status':'planned_unrun','actions':['Obtain real logical/physical/edit identity through retained Catalog methods.','Change recipe/metadata/source observations separately and retry stale CAS.'],'observables':['Physical fingerprint binds original bytes; logical metadata and edit generations remain independently scoped.','Stale identity callback is not executed.'],'faults':['Invalid VariantKey fails; mixed source/image key is rejected.'],'source_revision':catalog_source.verify(), 'upstream_revision':PIN}
    profiles['full-float-original']={'id':'full-float-original','family':'public_core','status':'planned_unrun','actions':['Use CPU-only native full TIFF decoder with negative/high fractional f32 pixels and known BLAKE3.','Apply exact retained recipe renderer and stage to a fresh destination.'],'observables':['Linear f32 precision survives; provenance and receipt bind actual source and recipe identities.','Source bytes remain identical and browse JPEG cannot satisfy exact input.'],'faults':['Wrong fingerprint or decoded allocation limit fails before admission.','Cancellation/stale source blocks publication.'],'source_revision':catalog_source.verify(), 'upstream_revision':PIN}
    profiles['wire-conformance']={'id':'wire-conformance','family':'typed_transport','status':'planned_unrun','actions':['For every wire case, deserialize into exact Rust application::Request and Swift LWApplicationRequest.','Serialize Swift request back and deserialize Rust again; compare typed value via JSON tree, including defaults and flattened fields.'],'observables':['Every source enum discriminator and associated field survives its exact serde representation.','Canonical decimal strings and lossless NativePath byte/wide units are preserved.'],'faults':['Unknown enum discriminator/denied unknown field and noncanonical decimal forms fail.'],'source_revision':catalog_source.verify(), 'upstream_revision':PIN}
    for profile in profiles.values():
        profile.setdefault('baseline_test_evidence',baseline_test_evidence(profile['family']))
    cases=[]
    for identity,path in sorted(paths.items()):
        node=nodes[identity]
        for variant in node['variants']:
            family=fixture_family(identity,path,variant['name']); profile=FAMILIES[family][0]
            selections={edge['type_id']:edge['variant'] for edge in path if edge['variant']}; selections[identity]=variant['name']
            sample=wire_sample(nodes,'application::dto::Request',selections)
            command_chain=[{'type_id':edge['type_id'],'variant':edge['variant']} for edge in path if nodes[edge['type_id']]['name']=='Request']
            if node['name']=='Request':command_chain.append({'type_id':identity,'variant':variant['name']})
            results=[]
            for command in command_chain:
                result_type=command['type_id'].rsplit('::',1)[0]+'::Response'
                if command['type_id']=='application::preview_settings::Request':
                    results.append({'type_id':'application::preview_settings::Status','variants':[]}); continue
                results.append({'type_id':result_type,'variants':RESULTS[command['type_id']][command['variant']]})
            key=identity+'::'+variant['name']
            caps.append({'id':key,'kind':'request_variant' if node['name']=='Request' else 'nested_input_variant','story_id':'sc-24658','source':{'file':node['file'],'symbol':key,'line':variant['line']},'request_path':path,'typed_results':results,'fixture_profile':profile,'wire_fixture':key,'acceptance_status':'planned_unrun','fault_fixture':profile})
            cases.append({'id':key,'request':sample,'status':'planned_unrun','scope':'typed_serde_conformance_only','semantic_context':'Session/job/guard/token/revision/digest/path values must be replaced by successful preceding lifecycle replies before operational invocation. Placeholder specimen strings do not grant filesystem or database authority.','fixture_profile':'wire-conformance'})
        for variant_name, field in [(None,f) for f in node['fields']]+[(v['name'],f) for v in node['variants'] for f in v['fields']]:
            key=identity+('::'+variant_name if variant_name else '')+'.'+field['name'];family=fixture_family(identity,path,variant_name)
            caps.append({'id':key,'kind':'request_field','story_id':'sc-24658','source':{'file':node['file'],'symbol':key,'line':field['line']},'rust_type':field['rust_type'],'serde':field.get('serde',{}),'request_path':path,'fixture_profile':FAMILIES[family][0],'acceptance_status':'planned_unrun','fault_fixture':FAMILIES[family][0]})
    for key,file,symbol,profile,actions in CORE_SEAMS:
        path=SOURCE/file;text=path.read_text();match=re.search(r'pub fn '+re.escape(symbol)+r'\b',text)
        if not match:raise ValueError('public seam missing '+symbol)
        caps.append({'id':'core::'+key,'kind':'public_core_seam','story_id':'sc-24658','source':{'file':str(path.relative_to(ROOT)),'symbol':symbol,'line':text.count('\n',0,match.start())+1},'fixture_profile':profile,'actions':actions,'acceptance_status':'planned_unrun','fault_fixture':profile})
    ledger={item['file']:item for item in data['source_files']}
    extra={cap['source']['file'] for cap in caps}|{e['file'] for profile in profiles.values() for e in profile['baseline_test_evidence']}
    extra |= {'engines/catalog/src/application/exports/read.rs','engines/catalog/src/application/exports/worker.rs','engines/catalog/src/application/desktop/migration.rs'}
    for filename in sorted(extra): ledger[filename]={'file':filename,'sha256':sha((ROOT/filename).read_bytes())}
    data['source_files']=[ledger[k] for k in sorted(ledger)]
    typed_wire_cases=[]
    for node in data['types']:
        if not node['wire_serializable']:continue
        if node['kind']=='struct' and not node.get('generic_parameters'):
            typed_wire_cases.append({'id':node['id']+'::struct','type_id':node['id'],'value':wire_sample(nodes,node['id'],populated=True),'source':{'file':node['file'],'line':node['line']},'scope':'typed_serde_conformance_only','fixture_profile':'wire-conformance','status':'planned_unrun'})
        if node['kind']!='enum':continue
        for variant in node['variants']:
            identity=node['id']+'::'+variant['name']
            typed_wire_cases.append({'id':identity,'type_id':node['id'],'value':wire_sample(nodes,node['id'],{node['id']:variant['name']},populated=True),'source':{'file':node['file'],'line':variant['line']},'scope':'typed_serde_conformance_only','fixture_profile':'wire-conformance','status':'planned_unrun'})
    data['typed_wire_cases']=typed_wire_cases
    data.update(capabilities=caps,fixture_profiles=profiles,wire_cases=cases,request_type_ids=sorted(i for i in paths if nodes[i]['name']=='Request'),request_reachable_type_ids=sorted(paths),request_variant_count=sum(len(nodes[i]['variants']) for i in paths if nodes[i]['name']=='Request'),request_reachable_variant_count=sum(len(nodes[i]['variants']) for i in paths),status='complete_source_mapping_native_execution_unrun')
    return data


def markdown(data):
    variants = sum(len(node['variants']) for node in data['types'])
    counts = collections.Counter(cap['kind'] for cap in data['capabilities'])
    out = ['# Catalog service capability coverage', '', f"LensWorks-owned catalog (upstream provenance `{PIN}`); story `sc-24658`. {len(data['types'])} reachable request/result/config/core types and {variants} enum variants; {data['request_variant_count']} commands and {data['request_reachable_variant_count']} input enum choices. Source coverage is not native acceptance.", '',
           f"The matrix contains {counts['request_variant']} command rows, {counts['nested_input_variant']} nested input choice rows, {counts['request_field']} associated/struct field rows and {counts['public_core_seam']} public original/render identity seams. Every row maps to a concrete fixture profile. All execution is planned/unrun unless exact evidence appears in the JSON execution ledger.", '',
           f"The JSON contains the complete field/type/serde/import graph, all source hashes, all capability rows and {len(data['wire_cases'])} full Request specimens. Its {len(data['typed_wire_cases'])} standalone specimens cover serialized enum variants and every nongeneric serialized struct, with populated vectors/options and concrete generic Page rows/cursors. Workbench Rows projects public lightroom::plan::Cell, retained as an explicit result root. Specimens establish serialization shape only; real session/job/guard/token/revision/digest/path values must come from preceding successful lifecycle replies, and specimen strings grant no authority.", '',
           '## Public request and typed result matrix', '', '| Source type / command | Typed successful result | Lifecycle fixture | Status |', '| --- | --- | --- | --- |']
    for cap in data['capabilities']:
        if cap['kind'] != 'request_variant': continue
        responses = '; '.join(r['type_id'] + ('::{' + ', '.join(r['variants']) + '}' if r['variants'] else '') for r in cap['typed_results'])
        out.append(f"| `{cap['id']}` | `{responses}` | `{cap['fixture_profile']}` | {cap['acceptance_status']} |")
    out += ['', '## Concrete lifecycle fixtures', '']
    for identity, profile in data['fixture_profiles'].items():
        out += ['### ' + identity, '', 'Status: **' + profile['status'] + '**. Source baseline: `' + profile['source_revision'] + '`.', '']
        out += [str(index) + '. ' + action for index, action in enumerate(profile['actions'], 1)]
        out += ['', 'Required observables:', ''] + ['- ' + value for value in profile['observables']]
        out += ['', 'Fault fixtures:', ''] + ['- ' + value for value in profile['faults']] + ['']
    out += ['## Public source identity and full precision seams', '', '| Source symbol | Fixture | Concrete action |', '| --- | --- | --- |']
    for cap in data['capabilities']:
        if cap['kind'] == 'public_core_seam':
            out.append(f"| `{cap['source']['file']}:{cap['source']['line']}::{cap['source']['symbol']}` | `{cap['fixture_profile']}` | {' '.join(cap['actions'])} |")
    out += ['', 'Full precision linear f32 decoding and verified source identity are independent public Rust seams; retained preview/browse JPEG or Compositor RGBA8 is insufficient acceptance. PSD/PSB import does not grant an export route. Frozen license/provenance remain in DEPENDENCIES.json and THIRD_PARTY_NOTICES.md.', '',
            '## Audit contract', '', 'Run `python3 scripts/audit-catalog-service-coverage.py --check-swift`. The audit independently extracts module-scope declarations/imports and exact fields/serde tags/macro-expanded limits and decimal wrappers, verifies the owned source digest and file hashes, and rejects missing coverage or changed source authority. It checks actual Swift associated/struct payload types, not just member names. `--self-test-source-resolution` executes lexical-scope/local-shadow/module-alias/reexport-cycle/wildcard-ambiguity regressions, populated generic pages, and negative wrong graph/Swift type bindings. `--write` regenerates source-derived artifacts; none of these commands execute operational acceptance fixtures.', '',
            '## Source ambiguities and execution limits', '',
            'All reachable type references resolve. Runtime authority values and lifecycle success are intentionally unresolved until actual fixture setup returns them. Typed Error replies are fault evidence and never count as a successful workflow. Migration Cancel can return Discarded before upload activation; export inactive Cancel returns Job while active Cancel returns Operation. These alternate successful result forms are explicitly retained.', '']
    return '\n'.join(out).rstrip() + '\n'

def validate(recorded, actual):
    errors = []
    for key in ['baseline','types','source_files','capabilities','wire_cases','typed_wire_cases','request_type_ids','request_reachable_type_ids','fixture_profiles']:
        if recorded.get(key) != actual[key]: errors.append(key + ' source-derived coverage changed, missing or falsely accepted')
    nodes = {node['id']:node for node in actual['types']}
    seen = set()
    for cap in recorded.get('capabilities', []):
        if cap['id'] in seen: errors.append('duplicate capability: ' + cap['id'])
        seen.add(cap['id'])
        if cap.get('story_id') != 'sc-24658': errors.append('invalid story: ' + cap['id'])
        for key in ['fixture_profile','fault_fixture']:
            if cap.get(key) not in recorded.get('fixture_profiles', {}): errors.append('missing concrete fixture: ' + cap['id'])
        for result in cap.get('typed_results', []):
            node = nodes.get(result['type_id'])
            if not node or any(variant not in {v['name'] for v in node['variants']} for variant in result['variants']): errors.append('invalid result mapping: ' + cap['id'])
    for identity, profile in recorded.get('fixture_profiles', {}).items():
        if any(not profile.get(key) for key in ['actions','observables','faults','source_revision']): errors.append('incomplete fixture profile: ' + identity)
    for evidence in recorded.get('execution_evidence', []):
        if evidence.get('baseline_revision') != PIN or evidence.get('source_digest') != actual['baseline']['source_digest'] or not evidence.get('command') or not evidence.get('adapter_revision') or not evidence.get('result_file') or not evidence.get('result_sha256'):
            errors.append('execution evidence lacks exact owned-source/upstream/adapter/command/result hash')
        else:
            result = ROOT / evidence['result_file']
            if not result.is_file() or sha(result.read_bytes()) != evidence['result_sha256']: errors.append('execution evidence file/hash unavailable')
    return errors

def swift_field_type(field):
    """Independently bind every declared Swift payload type to its source token."""
    if field.get('serde',{}).get('with') == 'hex_bytes': return 'LWCatalogHexBytes'
    refs = {r['rust_token']:r['type_id'] for r in field.get('type_refs',[])}
    primitive = {'String':'String','str':'String','bool':'Bool','usize':'UInt','isize':'Int',
                 'f32':'LWCatalogFloat32','f64':'LWCatalogFloat64','serde_json::Value':'LWCatalogJSON',
                 **{f'u{n}':f'UInt{n}' for n in (8,16,32,64)},
                 **{f'i{n}':f'Int{n}' for n in (8,16,32,64)}}
    def convert(typ):
        typ=typ.strip()
        if typ in primitive:return primitive[typ]
        generic=re.fullmatch(r'([\w:]+)\s*<(.+)>',typ)
        if generic:
            base,body=generic.groups();arguments=[convert(t) for _,t in split(body)]
            if base=='Option':return arguments[0]+'?'
            if base=='Box':return arguments[0]
            if base in {'Vec','BTreeSet','HashSet'}:return '['+arguments[0]+']'
            if base in {'BTreeMap','HashMap'}:return '['+arguments[0]+':'+arguments[1]+']'
            return convert(base)+'<'+','.join(arguments)+'>'
        if typ.startswith('(') and typ.endswith(')'):
            arguments=[convert(t) for _,t in split(typ[1:-1])]
            return {2:'LWCatalogPair',3:'LWCatalogTriple'}[len(arguments)]+'<'+','.join(arguments)+'>'
        if typ.startswith('[') and typ.endswith(']'):
            item,count=typ[1:-1].split(';');count=int(count)
            return {2:'LWCatalogPair',3:'LWCatalogTriple'}[count]+'<'+','.join([convert(item)]*count)+'>'
        identity=refs.get(typ)
        if identity:
            if identity=='storage_volume::NativePath':return 'LWCatalogNativePath'
            if identity.rsplit('::',1)[-1] in {'I64','U64','U128'}:return 'LWCatalog'+identity.rsplit('::',1)[-1]
            return 'LW'+''.join(p[0].upper()+p[1:] for part in identity.split('::') for p in part.split('_'))
        if typ in field.get('generic_parameter_refs',[]):return typ
        raise ValueError('unbound Swift source type: '+typ)
    return convert(field['rust_type'])

def validate_swift(data, text=None):
    path=ROOT/'native/Compositor/LensWorks/LensWorksCatalogDTO.swift'
    if text is None:
        if not path.is_file(): return ['Swift typed facade absent']
        text=path.read_text()
    errors=[]
    for node in data['types']:
        if not node['wire_serializable'] or node['kind']=='decimal_string' or node['id']=='storage_volume::NativePath':continue
        marker='/// '+node['id']+' ('
        if marker not in text:errors.append('Swift type missing: '+node['id']);continue
        block=text[text.index(marker):].split('\n/// ',1)[0]
        header=block.split('init(from decoder',1)[0]
        if node['kind']=='enum':
            declared=[v.strip('`') for v in re.findall(r'^\s+case (\w+|`[^`]+`)',header,re.M)]
            if declared != [v['name'] for v in node['variants']]:errors.append('Swift variant omission/change: '+node['id'])
            for variant in node['variants']:
                match=re.search(r'^\s+case `?'+re.escape(variant['name'])+r'`?\(([^\n]*)\)',header,re.M)
                expected=','.join((f['name']+':' if variant['shape']=='struct' else '')+swift_field_type(f) for f in variant['fields'])
                actual=re.sub(r'\s|`','',match.group(1)) if match else ''
                if actual!=expected:errors.append('Swift associated source type mismatch: '+node['id']+'::'+variant['name']+' expected '+expected+' got '+actual)
        elif node['kind']=='struct':
            declared=[v.strip('`') for v in re.findall(r'^\s+var (\w+|`[^`]+`)\s*:',header,re.M)]
            expected=[f['name'] if not f['name'].isdigit() else 'value'+f['name'] for f in node['fields']]
            if declared!=expected:errors.append('Swift field omission/change: '+node['id'])
            for name,field in zip(expected,node['fields']):
                match=re.search(r'^\s+var `?'+re.escape(name)+r'`?\s*:\s*([^\n]+)',header,re.M)
                actual=re.sub(r'\s','',match.group(1)) if match else ''
                expected_type=swift_field_type(field)
                if actual!=expected_type:errors.append('Swift field source type mismatch: '+node['id']+'.'+name+' expected '+expected_type+' got '+actual)
    return errors


def rust_wire_fixture(data):
    """Emit executable serde assertions using the owned crate's public reexports."""
    aliases = {
        'application::dto::': 'application::',
        'application::exports::dto::': 'application::exports::',
        'application::lightroom_bridge::wire::': 'application::lightroom_bridge::',
        'edit::recipe::': 'edit::',
        'image_export::specification::': 'image_export::',
        'lightroom::plan::selection::preparation::': 'lightroom::plan::selection::',
        'lightroom_migration_worker::worker::Operation': 'application::lightroom_migration::Operation',
        'lightroom_migration_worker::input::PartDescriptor': 'application::lightroom_migration::PartDescriptor',
        'media::full::': 'media::',
        'preview::codec::': 'preview::',
        'preview::store::': 'preview::',
        'preview::service::': 'preview::',
    }
    lines = ['// Source-generated typed serde fixtures; no successful service invocation is claimed.',
             '#[test]', 'fn all_source_standalone_wire_variants_decode_and_reencode() {',
             '    fn check<T: serde::de::DeserializeOwned + serde::Serialize>(id: &str, json: &str) {',
             '        let typed: T = serde_json::from_str(json).unwrap_or_else(|e| panic!("{id}: {e}"));',
             '        let expected: serde_json::Value = serde_json::from_str(json).unwrap();',
             '        let actual = serde_json::to_value(typed).unwrap();',
             '        assert_eq!(actual, expected, "{id}");', '    }']
    for case in data['typed_wire_cases']:
        public = case['type_id']
        for prefix, replacement in aliases.items():
            if public.startswith(prefix):
                public = replacement + public[len(prefix):]; break
        encoded = json.dumps(case['value'], separators=(',', ':'))
        lines.append('    check::<photocatalog::' + public + '>(' + json.dumps(case['id']) + ', r####"' + encoded + '"####);')
    lines.append('}')
    return '\n'.join(lines)

def source_resolution_regressions():
    """Exercise scope/authority failures independently of serialized inventory."""
    text='''use crate::remote::Field as Imported;
use crate::remote as model;
use crate::remote::*;
fn nested() {\n use crate::wrong::Field;\n}
mod child {\n use crate::wrong::Field;\n}
impl Local { fn nested() {\n use crate::wrong::Field;\n} }
'''
    imports,stars=imports_for(text,'scope')
    assert 'Field' not in imports and imports['Imported']=='remote::Field'
    nodes={key:{} for key in ['scope::Field','remote::Field','wrong::Field']}
    modules={'scope':{'imports':imports,'stars':stars}}
    resolve=resolver(nodes,modules)
    assert resolve('Field','scope')=='scope::Field'
    assert resolve('Imported','scope')=='remote::Field'
    assert resolve('model::Field','scope')=='remote::Field'
    assert resolve('crate::wrong::Field','scope')=='wrong::Field'
    cycles={'a':{'imports':{'Field':'b::Field'}},'b':{'imports':{'Field':'a::Field'}}}
    assert resolver({},cycles)('a::Field','') is None
    ambiguous={'scope':{'stars':['remote','wrong']}}
    try: resolver({'remote::Field':{},'wrong::Field':{}},ambiguous)('Field','scope')
    except ValueError as error: assert 'ambiguous wildcard' in str(error)
    else: raise AssertionError('ambiguous wildcard silently selected authority')
    assert resolver(nodes,ambiguous)('Field','scope')=='scope::Field'
    actual=enrich(graph());by_id={n['id']:n for n in actual['types']}
    response=by_id['application::metadata::Response']
    variant=next(v for v in response['variants'] if v['name']=='Fields')
    assert variant['fields'][0]['type_refs']==[
        {'rust_token':'Page','type_id':'application::metadata::Page'},
        {'rust_token':'Field','type_id':'application::metadata::Field'}]
    specimen=next(c for c in actual['typed_wire_cases'] if c['id']=='application::metadata::Response::Fields')
    assert specimen['value']['value']['rows'] and isinstance(specimen['value']['value']['rows'][0],dict)
    assert set(specimen['value']['value']['rows'][0])=={f['name'] for f in by_id['application::metadata::Field']['fields']}
    assert specimen['value']['value']['next'] is not None
    organization=next(c for c in actual['typed_wire_cases'] if c['id']=='application::organization::Response::Keywords')
    assert organization['value']['value']['rows'] and organization['value']['value']['next'] is not None
    inspection=next(c for c in actual['typed_wire_cases'] if c['id']=='application::copy::Inspection::struct')
    crop=inspection['value']['recipe']['settings']['crop']
    assert isinstance(crop['left'],float) and crop['left']==struct.unpack('<f',struct.pack('<f',0.1))[0]
    assert crop['left']!=0.1 and crop['right']==struct.unpack('<f',struct.pack('<f',0.9))[0]
    bad=json.loads(json.dumps(actual))
    bad_response=next(n for n in bad['types'] if n['id']==response['id'])
    next(v for v in bad_response['variants'] if v['name']=='Fields')['fields'][0]['type_refs'][1]['type_id']='lightroom::migration_source::Field'
    assert any(e.startswith('types ') for e in validate(bad,actual))
    single={**response,'variants':[variant]}
    swift='/// '+response['id']+' (fixture).\nnonisolated enum Fixture {\n case Fields(LWApplicationMetadataPage<LWApplicationMetadataField>)\n init(from decoder: any Decoder) {}\n}'
    assert not validate_swift({'types':[single]},swift)
    assert any('source type mismatch' in e for e in validate_swift({'types':[single]},swift.replace('LWApplicationMetadataField','LWLightroomMigrationSourceField')))
    print('PASS SOURCE RESOLUTION REGRESSIONS: lexical imports/local shadowing/module aliases/reexport cycles/wildcard ambiguity; populated generic pages and IEEEf32; wrong graph and Swift payload types rejected')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    parser.add_argument('--check-swift', action='store_true', help='Audit actual generated Swift type/variant/field declarations against independent source graph')
    parser.add_argument('--emit-rust-wire-fixture', action='store_true', help='Print executable standalone serde assertions with public Rust type paths; no files are written')
    parser.add_argument('--allow-unresolved', action='store_true', help='Diagnostic extraction only; never acceptance')
    parser.add_argument('--self-test-source-resolution', action='store_true', help='Run bounded source scope and populated-result regression fixtures; no files written')
    args = parser.parse_args()
    if args.self_test_source_resolution:
        source_resolution_regressions();return
    catalog_source.verify()
    actual = enrich(graph())
    if args.emit_rust_wire_fixture:
        print(rust_wire_fixture(actual)); return
    if args.write:
        if OUTPUT.is_file():
            previous=json.loads(OUTPUT.read_text())
            if previous.get('baseline')==actual['baseline']: actual['execution_evidence']=previous.get('execution_evidence',[])
        OUTPUT.write_text(json.dumps(actual, indent=2) + '\n'); MARKDOWN.write_text(markdown(actual))
    recorded = json.loads(OUTPUT.read_text())
    errors = validate(recorded, actual)
    if recorded['types'] != actual['types']: errors.append('reachable DTO type/field/serde/variant graph changed or missing')
    if recorded['source_files'] != actual['source_files']: errors.append('source file/hash ledger changed')
    if actual['missing_roots']: errors.append('missing source roots: ' + repr(actual['missing_roots']))
    if actual['unresolved_type_references'] and not args.allow_unresolved: errors.append('unresolved reachable type references: ' + repr(actual['unresolved_type_references']))
    if args.check_swift:
        errors += validate_swift(actual)
    for error in errors: print('FAIL:', error)
    if errors: raise SystemExit(1)
    print(f"PASS SOURCE COVERAGE: {len(actual['types'])} types, {actual['request_variant_count']} commands, {actual['request_reachable_variant_count']} input variants, {len(actual['capabilities'])} mapped rows; native fixtures planned/unrun")

if __name__ == '__main__': main()
