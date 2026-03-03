from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PY_CMD = [str(ROOT / '.venv/bin/python'), str(ROOT / 'mt.py')]
RUST_CMD = [str(ROOT / 'ports/dist/rust-mt')]
ZIG_CMD = [str(ROOT / 'ports/dist/zig-mt')]

if not (ROOT / 'ports/dist/rust-mt').exists() or not (ROOT / 'ports/dist/zig-mt').exists():
    subprocess.run(['make', '-C', 'ports', 'release'], cwd=ROOT, check=True)


def parse_frontmatter(path: Path):
    text = path.read_text(encoding='utf-8')
    lines = text.splitlines()
    end_idx = next(i for i in range(1, len(lines)) if lines[i].strip() == '---')
    out = {}
    for line in lines[1:end_idx]:
        if ':' not in line:
            continue
        k, v = line.split(':', 1)
        out[k.strip()] = v.strip()
    return out


results = {}
for name, cmd in [('python', PY_CMD), ('rust', RUST_CMD), ('zig', ZIG_CMD)]:
    with tempfile.TemporaryDirectory(prefix=f'cmp-{name}-') as td:
        wd = Path(td)
        subprocess.run(['git', 'init', '-q'], cwd=wd, check=True)
        subprocess.run([*cmd, 'init'], cwd=wd, check=True, capture_output=True, text=True)
        subprocess.run([*cmd, 'new', 'Compare Ticket', '--label', 'alpha', '--tag', 'beta'], cwd=wd, check=True, capture_output=True, text=True)
        results[name] = parse_frontmatter(wd / 'tickets' / 'T-000002.md')

base = results['python']
print('Baseline keys (python):', sorted(base.keys()))
for other in ('rust', 'zig'):
    print(f"\n== {other} vs python ==")
    diffs = []
    merged_keys = sorted(set(base.keys()) | set(results[other].keys()))
    for key in merged_keys:
        if base.get(key) != results[other].get(key):
            diffs.append((key, base.get(key), results[other].get(key)))
    if not diffs:
        print('No differences')
    else:
        for key, a, b in diffs:
            print(f"{key}: python={a!r} | {other}={b!r}")
