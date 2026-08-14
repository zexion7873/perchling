#!/usr/bin/env python3
"""Regenerate deform-coverage.txt. Run this when a parameter is ADDED to
v6_deform and deliberately deformed -- never to make a red check_deform go
green, which is the only way this guard can be defeated."""
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from check_deform import moved_paths, AXES, COVERAGE

head = open(COVERAGE, encoding='utf-8').read().split('\n[')[0].rstrip()
out = [head]
for axis, (sq, wd) in AXES.items():
    out.append(f"\n[{axis}]")
    out += sorted(moved_paths(sq, wd))
open(COVERAGE, 'w', encoding='utf-8').write("\n".join(out) + "\n")
print(f"frozen {sum(len(moved_paths(*v)) for v in AXES.values())} paths")
