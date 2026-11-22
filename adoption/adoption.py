"""Writes deploy/adoption/<unit>.md, the adoption evidence that the approver of a unit's first run reads.

A deployment stack has no baseline before its first apply, so the first preview of a unit still lists differences
that Azure reports and a deployment does not change. The read-only sweep and the gate have already judged every
such record. This tool puts that result into one file per unit of deploy/units.json. It reads saved files only
and makes no Azure call.

usage: python adoption/adoption.py <sweep folder> <gate folder> --sweep "<words that name the sweep>"
                                   [--missing "<unit>=<why the sweep has no preview of it>"] [--bicep <path>]
  <sweep folder>  saved what-if results, one <unit>.json per unit in any subfolder. The preview of a
                  deploy-excluded unit is named <group>.deploy-excluded.json.
  <gate folder>   one <unit>.txt per unit, the output of scripts/deploy-unit.ps1 -Unit <unit> -WhatIfJson <file>.
  --bicep         the Bicep CLI that compiles each unit's template. Without it the tool uses the copy the Azure CLI
                  installed (bin/bicep in its configuration folder). It must be the version the workflows pin.

The tool counts every preview again. When its counts or its records differ from the gate's, the file of that unit
says so in its first lines and the tool ends with exit code 1.
Each file names the unit's template with the hash of its compiled template and the parameters file with the SHA256
of its text. The compiled template holds every module the template calls, so its hash changes with any of them. The
plan of a unit's first run compares both with the files of its commit, so run the tool on the code the previews
were taken from.
This tool is temporary. It is deleted with deploy/adoption/ once every unit has had its first run.
"""
import argparse, collections, hashlib, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = ['NoChange', 'Modify', 'Ignore', 'Create', 'Delete']
INTRO = ('This file is written by adoption/adoption.py from saved previews and is never edited by hand. A deployment '
         'stack has no baseline before its first apply, so the first preview of this unit still lists differences that '
         'Azure reports and a deployment does not change. This file gives the reason for each of those records, so the '
         'approver of the unit\'s first run does not have to judge them by eye. It is deleted after the unit\'s first run.')
LEGEND = ('Resources are written without the leading `/subscriptions/<ID>/`. The brackets after a property path hold what '
          'the preview reports for that property and the number of its reason. Create means the code sets the property '
          'and Azure does not return it, Delete means Azure returns it and the code leaves it out, Modify means the two '
          'values differ, and NoEffect means a deployment does not change it. The numbers in the Reason column point to '
          'the list under Reasons.')
TERMS = ('A boundary is a field Azure owns, whose difference the gate accepts (inert) or stops on for a person to read '
         '(review). A hold is a resource the gate refuses to deploy. An expected Ignore record is a live resource that '
         'is deliberately not declared in the unit that previews it.')
NO_FILE = ('**No record of this unit is judged here, so this file is not evidence yet.** This is not yet done because %s. '
           'Take a read-only preview of the unit, have the gate judge it and run adoption/adoption.py again before the '
           'unit\'s first run.')
COUNTS = ('Each count is the number of resources with that result in the plain preview (what-if) of the unit\'s template. A stack '
          'preview lists only the resources the template declares, so the Ignore records do not appear in it. The scope of the unit is %s.')
NOT_DECLARED = 'The live resource is not declared in this unit, so a deployment of the unit leaves it alone.'
NO_EFFECT = 'NoEffect. The preview lists the property and reports that a deployment does not set or change it.'


def read_text(path):
    """A saved preview is UTF-8 or, when az wrote it on Windows, code page 1252. The gate reads both."""
    with open(path, 'rb') as f: data = f.read()
    if data[:2] in (b'\xff\xfe', b'\xfe\xff'): return data.decode('utf-16')
    try: return data.decode('utf-8-sig')
    except UnicodeDecodeError: return data.decode('cp1252')


def text_hash(path):
    """SHA256 of a file's text as UTF-8 without a byte order mark and with LF line endings, so the value is the
    same on a Windows and a Linux checkout. The plan job of mirror-deploy-unit computes it the same way."""
    with open(path, 'rb') as f: text = f.read().decode('utf-8-sig')
    return hashlib.sha256(text.replace('\r\n', '\n').encode('utf-8')).hexdigest()


def pinned_bicep_version():
    """The Bicep version the workflows pin, read from the env block of mirror-deploy-unit.yml."""
    text = read_text(os.path.join(ROOT, '.github', 'workflows', 'mirror-deploy-unit.yml'))
    m = re.search(r'(?m)^  BICEP_VERSION: v?([0-9.]+)\s*$', text)
    if not m: sys.exit('STOP: .github/workflows/mirror-deploy-unit.yml names no BICEP_VERSION')
    return m.group(1)


def find_bicep(given):
    """The Bicep CLI to compile with. It must be the pinned version, because another version can give another hash."""
    exe = 'bicep.exe' if os.name == 'nt' else 'bicep'
    path = given or os.path.join(os.environ.get('AZURE_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.azure'), 'bin', exe)
    if not os.path.isfile(path): sys.exit('STOP: no Bicep CLI at %s. Install it with az bicep install --version v%s or give --bicep' % (path, pinned_bicep_version()))
    said = subprocess.run([path, '--version'], capture_output=True, text=True).stdout
    want = pinned_bicep_version()
    if not re.search(r'version ' + re.escape(want) + r'\b', said): sys.exit('STOP: %s is not Bicep %s (it says: %s)' % (path, want, said.strip()))
    return path


TEMPLATE_HASHES = {}


def template_hash(bicep, path):
    """The templateHash that Bicep writes into the compiled template of a .bicep file. The compiled template holds
    the template of every module inline, so the value changes when the file or any module it calls changes. The plan
    job of mirror-deploy-unit reads the same value from its own compile."""
    if path not in TEMPLATE_HASHES:
        run = subprocess.run([bicep, 'build', os.path.join(ROOT, path), '--stdout'], capture_output=True)
        if run.returncode != 0: sys.exit('STOP: %s does not compile:\n%s' % (path, run.stderr.decode('utf-8', 'replace')))
        TEMPLATE_HASHES[path] = str(json.loads(run.stdout.decode('utf-8-sig'))['metadata']['_generator']['templateHash'])
    return TEMPLATE_HASHES[path]


def resource_type(rid):
    i = rid.lower().rfind('/providers/')
    if i < 0: return 'Microsoft.Resources/resourceGroups'
    parts = rid[i + 11:].split('/')
    return '/'.join([parts[0]] + parts[1::2])


def leaves(nodes, prefix=''):
    """The gate's flattening of a what-if delta. One entry per changed property, array indices written as [*]."""
    out = []
    for node in nodes or []:
        seg = str(node.get('path'))
        path = seg if not prefix else prefix + ('[%s]' % seg if re.fullmatch(r'\d+', seg) else '.' + seg)
        if node.get('children'): out += leaves(node['children'], path)
        else: out.append((re.sub(r'\[\d+\]', '[*]', path), str(node.get('propertyChangeType'))))
    return out


def find_boundary(boundaries, rtype, path, kind):
    """The gate's rule. A pattern matches the path itself or anything below it, and ** matches any run of characters."""
    for b in boundaries:
        pattern = '^' + re.escape(b['path']).replace(r'\*\*', '.*') + r'($|[.\[])'
        if b['type'].lower() == rtype.lower() and kind in b['changeTypes'] and re.match(pattern, path, re.I): return b
    return None


def read_gate(path):
    """The header fields and the records of one gate output. A record line is the verdict, the result and the ID,
    and the lines indented under it are the gate's notes for that record."""
    head, records, current = {'Problem': []}, [], None
    for line in read_text(path).splitlines():
        m = re.match(r'(PASS|FAIL|REVIEW)\s+(\S+)\s+(/.*)$', line)
        if m: current = {'verdict': m[1], 'result': m[2], 'id': m[3].strip(), 'notes': []}; records.append(current)
        elif line.startswith(' ' * 17) and current: current['notes'].append(line.strip())
        elif re.match(r'(Problem|STOP):', line): head['Problem'].append(line.strip())
        elif re.match(r'[A-Za-z]+:\s', line): head[line.split(':', 1)[0]] = line.split(':', 1)[1].strip()
    return head, records


def record_reasons(record, change, boundaries):
    """The changed properties of one record, each with its reason, and all reasons of the record. A Modify gets the
    boundary of each changed property, which the gate applies and does not print. Everything else comes from the
    gate's own notes. The third value is True when a changed property has no boundary."""
    paths, reasons, unjudged = [], [], False
    if record['result'] == 'Modify':
        for path, kind in sorted(set(leaves(change.get('delta')))):
            b = find_boundary(boundaries, resource_type(record['id']), path, kind)
            if kind == 'NoEffect': why = NO_EFFECT
            elif b:
                words = ' '.join(filter(None, [b['reason'], b.get('note')]))
                why = '%s boundary of %s at `%s`. %s' % ('Review' if b['onDeploy'] == 'review' else 'Inert', b['type'], b['path'], words)
            else: unjudged, why = True, 'No boundary covers `%s` (%s), so the gate does not accept the record.' % (path, kind)
            paths.append((path, kind, why))
    for note in record['notes']:
        if note.startswith(('review boundary ', 'unclassified delta ')): continue   # the reason of the property says it
        if note.startswith('live resource not declared, so Incremental'): reasons.append(NOT_DECLARED)
        elif note.startswith('expected: '): reasons.append('Expected Ignore record. ' + note[10:])
        elif note.startswith('held: '): reasons.append('Hold. ' + note[6:])
        else: reasons.append(note[0].upper() + note[1:] + ('' if note.endswith('.') else '.'))
    return paths, list(dict.fromkeys([p[2] for p in paths] + reasons)), unjudged


def table(rows, numbers, with_gate):
    lines = ['| Resource | Result | %sProperty paths that differ | Reason |' % ('Gate | ' if with_gate else ''),
             '|---|---|---|---|' + ('---|' if with_gate else '')]
    for r in rows:
        cells = [re.sub(r'^/subscriptions/[^/]+/', '', r['id']).replace('|', '\\|'), r['result']] + ([r['verdict']] if with_gate else [])
        cells.append('<br>'.join('`%s` (%s, reason %d)' % (path, kind, numbers[why]) for path, kind, why in r['paths']))
        lines.append('| ' + ' | '.join(cells + [', '.join(str(numbers[x]) for x in r['reasons'])]) + ' |')
    return lines + ['']


def build(unit, preview, rel, gate_file, boundaries, sweep, missing, files, bicep):
    """Returns the text of one unit's file, a summary of it and the list of what makes the file unreliable."""
    title = ['# Adoption evidence for %s' % unit, '']
    if not preview or not os.path.isfile(gate_file):
        why = missing.get(unit) or ('the sweep holds no preview of the unit' if not preview else 'the gate has not judged the preview')
        return '\n'.join(title + [NO_FILE % why, '', 'The sweep that was read is %s.' % sweep, '']), None, []
    doc = json.loads(read_text(preview))
    changes = doc.get('changes') if doc.get('changes') is not None else (doc.get('properties') or {}).get('changes') or []
    head, records = read_gate(gate_file)
    gate = head.get('Gate', 'missing')
    counts = collections.Counter(c['changeType'] for c in changes)
    by_id = {c['resourceId'].lower(): c for c in changes}
    problems = list(head['Problem'])
    gate_counts = {k: int(v) for k, v in (x.split('=') for x in head.get('Counts', '').split())}
    if gate_counts != dict(counts): problems.append('The gate counted %s and the preview holds %s.' % (gate_counts, dict(counts)))
    in_preview = {(i, c['changeType']) for i, c in by_id.items()}
    listed = {(r['id'].lower(), r['result']) for r in records}
    if {x for x in in_preview if x[1] != 'NoChange'} != {x for x in listed if x[1] != 'NoChange'} or not listed <= in_preview:
        problems.append('The records the gate lists are not the records of the preview that are not NoChange.')
    for r in records:
        r['paths'], r['reasons'], unjudged = record_reasons(r, by_id.get(r['id'].lower(), {}), boundaries)
        if unjudged and r['verdict'] == 'PASS': problems.append('The gate accepted %s and no boundary covers one of its paths.' % r['id'])
    order = ['Create', 'Delete', 'Modify']
    records.sort(key=lambda r: (r['verdict'] == 'PASS', order.index(r['result']) if r['result'] in order else 3, r['id'].lower()))
    numbers, uses = {}, collections.Counter()
    for r in records:
        for text in r['reasons']: numbers.setdefault(text, len(numbers) + 1); uses[text] += 1
    refused, accepted = [r for r in records if r['verdict'] != 'PASS'], [r for r in records if r['verdict'] == 'PASS']
    out = title + ['**This file cannot be relied on. %s**' % p for p in problems]
    if refused:
        out.append('**The gate did not accept %d of the %d records of this unit. They are listed first, under Records the gate '
                   'did not accept, and their reasons must be read before the first run of the unit.**' % (len(refused), len(changes)))
    elif gate == 'PASS': out.append('The gate accepted every record of this unit.')
    else: out.append('**The gate result of this unit is %s.**' % gate)
    out += ['', INTRO, '']
    names = RESULTS + sorted(k for k in counts if k not in RESULTS)
    out += ['## Counts', '', '| ' + ' | '.join(names) + ' |', '|---' * len(names) + '|', '| ' + ' | '.join(str(counts.get(k, 0)) for k in names) + ' |', '',
            COUNTS % head.get('Scope', 'not stated'), '']
    if refused: out += ['## Records the gate did not accept', '', LEGEND, ''] + table(refused, numbers, True)
    if accepted: out += ['## Accepted records that are not NoChange', ''] + ([] if refused else [LEGEND, '']) + table(accepted, numbers, False)
    elif not refused: out += ['Every record of this unit is NoChange, so there is nothing to explain.', '']
    if numbers:
        out += ['## Reasons', '', TERMS, '']
        out += ['%d. %s This reason applies to %d record%s.' % (n, text.replace('<', '\\<'), uses[text], '' if uses[text] == 1 else 's') for text, n in numbers.items()]
        out.append('')
    out += ['## Source', '', 'The records come from %s, preview file `%s`. The gate judged them offline with scripts/deploy-unit.ps1 and '
            'deploy/boundaries.json, and its result for the unit is %s.' % (sweep, rel, gate), '',
            'The files of the unit the previews were taken from. The template has the hash that Bicep writes into its '
            'compiled template, which holds every module the template calls. The parameters file has the SHA256 of its '
            'text (line endings left out). The plan of the unit\'s first run computes both from the files of its commit and '
            'fails when one differs, because this evidence then belongs to another version of the unit.', '']
    out += ['- `%s` compiled template hash `%s`' % (f, template_hash(bicep, f)) if f.endswith('.bicep')
            else '- `%s` SHA256 `%s`' % (f, text_hash(os.path.join(ROOT, f))) for f in files] + ['']
    return '\n'.join(out), (gate, dict(counts), len(refused)), problems


def main():
    ap = argparse.ArgumentParser(description='Writes deploy/adoption/<unit>.md from a saved sweep and its gate output.')
    ap.add_argument('sweep_folder'); ap.add_argument('gate_folder'); ap.add_argument('--sweep', required=True)
    ap.add_argument('--missing', action='append', default=[]); ap.add_argument('--bicep')
    a = ap.parse_args()
    bicep = find_bicep(a.bicep)
    previews = {}
    for folder, _, files in os.walk(a.sweep_folder):
        for f in files:
            if not f.endswith('.json'): continue
            if f[:-5] in previews: sys.exit('STOP: the sweep folder holds two previews named %s' % f)
            previews[f[:-5]] = os.path.join(folder, f)
    boundaries = json.loads(read_text(os.path.join(ROOT, 'deploy', 'boundaries.json')))['boundaries']
    defs = json.loads(read_text(os.path.join(ROOT, 'deploy', 'units.json')))['units']
    units = [u['name'] for u in defs]
    files = {u['name']: [f for f in (u.get('template'), u.get('parameters')) if f] for u in defs}
    target = os.path.join(ROOT, 'deploy', 'adoption'); os.makedirs(target, exist_ok=True)
    missing, bad = dict(m.split('=', 1) for m in a.missing), 0
    for unit in units:
        preview = previews.get(unit.replace('-deploy-excluded', '.deploy-excluded')) or previews.get(unit)
        rel = os.path.relpath(preview, a.sweep_folder).replace('\\', '/') if preview else ''
        text, summary, problems = build(unit, preview, rel, os.path.join(a.gate_folder, unit + '.txt'), boundaries, a.sweep, missing, files[unit], bicep)
        with open(os.path.join(target, unit + '.md'), 'w', encoding='utf-8', newline='\n') as f: f.write(text)
        print(unit, summary if summary else 'NOT JUDGED', *problems, sep='\t')
        bad += len(problems)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
