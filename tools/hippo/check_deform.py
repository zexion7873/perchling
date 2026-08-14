#!/usr/bin/env python3
"""Guards on v6_deform. None of them replaces looking at the sheet.

Guard 1 binds this generator to `examples/perchling.json` — the manifest that
actually ships, which `perchling --export` prints verbatim. It used to compare
against the pre-deformation art module instead; binding to the shipped file is
strictly stronger, because it also goes red if the generator and the pet ever
drift apart, and it retires that module from this directory entirely.

It proves NOTHING about completeness: at sq=0, wd=0 every transform is the
identity, so a table the transform forgot passes it too.

Guard 2 is the one that hunts a forgotten table, and it is the SECOND design.
The first asserted that every ink's topmost row moves under a squash. It passed
on the first run and was then shown, by deliberately freezing the forelimbs, to
catch that mutation zero times out of ten -- the limbs sit inside the body
silhouette, so nothing about them reaches any ink's extreme row. A per-pixel
comparison against a nearest-neighbour resample was measured as a replacement
and separated 39-55 (honest) from 64-108 (stuck), which is not a margin worth
a threshold. What actually discriminates is structural: compare the SET of
parameter leaves the transform moves against a frozen list. A table nobody
deformed is simply absent from it.
"""
import sys, os, json
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import v6_deform

MOODS = ['done', 'error', 'idle', 'running', 'waiting']
SHIPPED = os.path.join(ROOT, 'examples', 'perchling.json')
AXES = {'sq': (4.0, 0.0), 'wd': (0.0, 2.0)}
COVERAGE = os.path.join(HERE, 'deform-coverage.txt')


def leaves(o, path=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from leaves(v, f"{path}.{k}" if path else str(k))
    elif isinstance(o, (list, tuple)):
        for i, v in enumerate(o):
            yield from leaves(v, f"{path}[{i}]")
    elif isinstance(o, (int, float)) and not isinstance(o, bool):
        yield path, float(o)


def moved_paths(sq, wd):
    """Parameter leaves this deformation actually changes."""
    base = dict(leaves(v6_deform._BASE))
    v6_deform._apply(sq, wd)
    now = dict(leaves({k: getattr(v6_deform, k) for k in v6_deform._BASE}))
    v6_deform._apply(0.0, 0.0)
    return {k for k in base if k in now and abs(now[k] - base[k]) > 1e-9}


def read_frozen():
    out, axis = {}, None
    for line in open(COVERAGE, encoding='utf-8'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('['):
            axis = line[1:-1]; out[axis] = set()
        else:
            out[axis].add(line)
    return out


def main():
    fail = 0

    print("GUARD 1 -- at rest, this generator reproduces the SHIPPED pet exactly")
    shipped = json.load(open(SHIPPED, encoding='utf-8'))['moods']
    for m in MOODS:
        got = [''.join(c if c else '.' for c in row) for row in v6_deform.build(m, 0.0, 0.0)]
        if got != shipped[m]:
            print(f"FAIL identity: {m} differs from examples/perchling.json"); fail += 1
        else:
            print(f"ok   identity: {m}")

    print("\nGUARD 2 -- the deformation reaches every parameter it is frozen to reach")
    frozen = read_frozen()
    for axis, (sq, wd) in AXES.items():
        got = moved_paths(sq, wd)
        missing = sorted(frozen[axis] - got)
        extra = sorted(got - frozen[axis])
        for k in missing:
            print(f"FAIL [{axis}] not deformed: {k}"); fail += 1
        for k in extra:
            print(f"FAIL [{axis}] deformed but not frozen: {k}"); fail += 1
        if not missing and not extra:
            print(f"ok   [{axis}] {len(got)} parameter leaves, exactly as frozen")

    print("\nGUARD 3 -- the floor never moves, whatever the deformation")
    for sq in (4.0, -3.0):
        for m in MOODS:
            rest = v6_deform.build(m, 0.0, 0.0)
            defo = v6_deform.build(m, sq, 0.0)
            fr = max(y for y, r in enumerate(rest) if any(r))
            fd = max(y for y, r in enumerate(defo) if any(r))
            if fr != fd:
                print(f"FAIL floor moved: {m} sq={sq} {fr} -> {fd}"); fail += 1
        print(f"ok   sq={sq}: every mood still stands on row "
              f"{max(y for y, r in enumerate(v6_deform.build('idle', 0.0, 0.0)) if any(r))}")

    print(f"\n{'FAILED' if fail else 'ok'}: {fail} problems")
    return 1 if fail else 0


if __name__ == '__main__':
    sys.exit(main())
