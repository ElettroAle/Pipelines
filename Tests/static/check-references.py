#!/usr/bin/env python3
"""
check-references.py

Verifica che ogni 'template:' referenziato nei file YAML di V3/
punti a un file che esiste realmente nel repository.

Regole:
- Scansiona solo V3/ (V1, V2, Test, Tests esclusi)
- Ignora riferimenti con '@repoAlias' (template da repo esterni)
- Risolve path relativi rispetto al file che li contiene
- Exit 1 se almeno un riferimento è rotto
"""

import sys
import os
import re
import yaml
from pathlib import Path


def find_yaml_files(root: Path) -> list[Path]:
    """Trova tutti i file .yaml/.yml sotto V3/, escludendo cartelle non pertinenti."""
    results = []
    for p in sorted(root.rglob("*.yaml")) + sorted(root.rglob("*.yml")):
        parts = p.parts
        # Escludi V1, V2, Test (bozze), Tests (questa suite), .github
        skip_dirs = {"V1", "V2", "Test", "Tests", ".github"}
        if any(d in parts for d in skip_dirs):
            continue
        results.append(p)
    return results


def extract_template_refs(file_path: Path) -> list[str]:
    """
    Estrae tutti i valori di chiave 'template:' da un file YAML.
    Usa regex invece di yaml.load per evitare problemi con template ADO
    che contengono sintassi non standard (${{ }}, ecc.).
    """
    refs = []
    try:
        content = file_path.read_text(encoding="utf-8")
    except Exception as e:
        print(f"  [WARN] Cannot read {file_path}: {e}")
        return refs

    # Cerca pattern: 'template: path/to/file.yaml' con indentazione variabile
    # Il valore può essere su stessa riga o su riga successiva con indentazione
    pattern = re.compile(r"^\s*template\s*:\s*(.+)$", re.MULTILINE)
    for match in pattern.finditer(content):
        ref = match.group(1).strip().strip("'\"")
        # Rimuovi parametri inline tipo @alias o ?params
        refs.append(ref)
    return refs


def resolve_ref(ref: str, source_file: Path, repo_root: Path) -> tuple[bool, str]:
    """
    Risolve un riferimento template e verifica se il file esiste.

    Restituisce (is_external, resolved_path_str).
    - is_external=True: riferimento con @alias, skippa
    - is_external=False: path locale, verifica esistenza
    """
    # Riferimento a repo esterno: contiene '@'
    if "@" in ref:
        return True, ref

    # Strippi eventuali parametri (caratteri dopo il .yaml)
    # es: "path/file.yaml" rimane tale
    path_part = ref.split(" ")[0]  # ignora eventuali spazi e testo dopo

    source_dir = source_file.parent

    if path_part.startswith("/"):
        # Path assoluto dalla root del repo
        resolved = repo_root / path_part.lstrip("/")
    else:
        # Path relativo alla directory del file sorgente
        resolved = (source_dir / path_part).resolve()

    return False, str(resolved)


def main():
    # Determina la root del repo: due livelli sopra questo script
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent  # Tests/static/ -> Tests/ -> repo root

    v3_root = repo_root / "V3"
    if not v3_root.exists():
        print(f"[ERROR] Cartella V3 non trovata in {repo_root}")
        sys.exit(1)

    yaml_files = find_yaml_files(repo_root)
    if not yaml_files:
        print("[WARN] Nessun file YAML trovato in V3/")
        sys.exit(0)

    errors = []
    checked = 0
    skipped_external = 0

    print(f"Scansione di {len(yaml_files)} file YAML in V3/...\n")

    for yaml_file in yaml_files:
        refs = extract_template_refs(yaml_file)
        for ref in refs:
            is_external, resolved = resolve_ref(ref, yaml_file, repo_root)

            if is_external:
                skipped_external += 1
                continue

            checked += 1
            if not Path(resolved).exists():
                rel_source = yaml_file.relative_to(repo_root)
                errors.append(
                    f"  {rel_source}\n"
                    f"    template: {ref}\n"
                    f"    -> Risolto in: {resolved}\n"
                    f"    -> FILE NON TROVATO"
                )

    print(f"Riferimenti controllati: {checked}")
    print(f"Riferimenti esterni skippati (@alias): {skipped_external}")
    print()

    if errors:
        print(f"[FAIL] {len(errors)} riferimento/i rotto/i:\n")
        for err in errors:
            print(err)
        sys.exit(1)
    else:
        print(f"[PASS] Tutti i {checked} riferimenti locali sono validi.")
        sys.exit(0)


if __name__ == "__main__":
    main()
