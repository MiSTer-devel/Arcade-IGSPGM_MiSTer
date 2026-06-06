#!/usr/bin/env python3
"""Headless FST signal inspector using pywellen (the surfer-mcp backend).

Usage:
  uv run --directory ~/Source/surfer-mcp python <thisfile> <trace.fst> <signal-substr> [more-substrs...]

Prints all transitions of any signal whose full path contains one of the
given substrings. Handy for inspecting IGS022/IGS025 protection behavior
without launching the Surfer GUI.
"""
import sys
from pywellen import Waveform


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]
    needles = sys.argv[2:]
    wave = Waveform(path)
    h = wave.hierarchy
    matched = []
    for var in h.all_vars(wave):
        name = var.full_name(h)
        if any(n in name for n in needles):
            matched.append((name, var))
    print(f"matched {len(matched)} signals")
    for name, var in matched:
        sig = wave.get_signal(var)
        changes = list(sig.all_changes())
        print(f"\n== {name} ({len(changes)} transitions) ==")
        for t, v in changes[:200]:
            try:
                vv = f"0x{int(v):x}"
            except Exception:
                vv = str(v)
            print(f"  t={t}: {vv}")


if __name__ == "__main__":
    main()
