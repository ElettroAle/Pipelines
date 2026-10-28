#!/usr/bin/env python3
"""
check-spdx.py

Verifica che ogni file sorgente di V3/ e V4/ dichiari la licenza con
l'header SPDX 'SPDX-License-Identifier: Apache-2.0'.

Regole:
- Scansiona solo V3/ e V4/ (V1, V2 sono legacy)
- Estensioni con commento '#': .yaml, .yml, .ps1, .psd1, .toml
- Estensioni con commento '//': .mjs, .cs
- L'header va nelle prime righe: nei .cs le direttive '#:' restano in cima
- Exit 1 se almeno un file non ha l'header
"""

import sys
from pathlib import Path

TAG = "SPDX-License-Identifier: Apache-2.0"
HASH_COMMENT = {".yaml", ".yml", ".ps1", ".psd1", ".toml"}
SLASH_COMMENT = {".mjs", ".cs"}
ROOTS = ("V3", "V4")
HEAD_LINES = 5


def expected_header(path: Path) -> str:
    return ("# " if path.suffix in HASH_COMMENT else "// ") + TAG


def has_header(path: Path) -> bool:
    with path.open(encoding="utf-8-sig") as f:
        head = [f.readline().rstrip("\r\n") for _ in range(HEAD_LINES)]
    return expected_header(path) in head


def main():
    # Determina la root del repo: due livelli sopra questo script
    repo_root = Path(__file__).resolve().parent.parent.parent

    files = [
        p
        for root in ROOTS
        if (repo_root / root).exists()
        for p in sorted((repo_root / root).rglob("*"))
        if p.is_file() and p.suffix in HASH_COMMENT | SLASH_COMMENT
    ]

    missing = [p for p in files if not has_header(p)]

    if missing:
        print(f"[FAIL] {len(missing)} file senza header SPDX:\n")
        for p in missing:
            print(f"  {p.relative_to(repo_root)}  (atteso: '{expected_header(p)}')")
        sys.exit(1)

    print(f"[PASS] Tutti i {len(files)} file sorgente hanno l'header SPDX.")
    sys.exit(0)


if __name__ == "__main__":
    main()
