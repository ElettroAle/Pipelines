#!/usr/bin/env python3
"""
check-parameters.py

Verifica i contratti parametri tra file YAML nella libreria V3:
per ogni coppia (template: X, parameters: {...}), controlla che tutti
i nomi di parametro passati esistano nella definizione del template X.

Regole:
- Scansiona solo V3/ (V1, V2, Test, Tests esclusi)
- Ignora riferimenti con '@repoAlias' (template da repo esterni)
- I parametri passati devono essere un sottoinsieme di quelli definiti in X
- Exit 1 se almeno un parametro sconosciuto viene passato
"""

import sys
import re
from pathlib import Path


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def read_file(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except Exception as e:
        print(f"  [WARN] Cannot read {path}: {e}")
        return None


def extract_defined_params(content: str) -> set[str]:
    """
    Estrae i nomi dei parametri definiti nella sezione top-level 'parameters:'
    di un template (la lista di definizioni, non i blocchi parameters passati).

    Cerca il pattern:
        parameters:
          - name: nomeparam
    """
    names = set()
    # Cerca 'parameters:' seguito da righe '  - name: xxx'
    in_params = False
    for line in content.splitlines():
        stripped = line.strip()
        if re.match(r"^parameters\s*:", stripped):
            in_params = True
            continue
        if in_params:
            # Fine del blocco parameters (altra chiave top-level o fine file)
            if stripped and not stripped.startswith("-") and not stripped.startswith("#"):
                if not line.startswith(" ") and not line.startswith("\t"):
                    in_params = False
                    continue
            m = re.match(r"-\s*name\s*:\s*(\S+)", stripped)
            if m:
                names.add(m.group(1).strip("'\""))
    return names


def find_template_calls(content: str) -> list[dict]:
    """
    Trova tutte le occorrenze di:
        - template: path/to/file.yaml
          parameters:
            key1: val1
            key2: val2

    Restituisce lista di dict: {template, params: [str], line_no}
    """
    calls = []
    lines = content.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"(\s*)-\s*template\s*:\s*(.+)", line)
        if m:
            indent = len(m.group(1))
            template_ref = m.group(2).strip().strip("'\"")
            line_no = i + 1
            params_found = []

            # Cerca un blocco 'parameters:' nelle righe successive
            j = i + 1
            while j < len(lines):
                next_line = lines[j]
                # Fine del blocco se indentazione torna al livello del '-'
                if next_line.strip() == "":
                    j += 1
                    continue
                current_indent = len(next_line) - len(next_line.lstrip())
                if current_indent <= indent and next_line.strip() and not next_line.strip().startswith("#"):
                    break
                pm = re.match(r"\s*parameters\s*:", next_line)
                if pm:
                    # Leggi le chiavi del blocco parameters
                    k = j + 1
                    params_indent = None
                    while k < len(lines):
                        param_line = lines[k]
                        if param_line.strip() == "" or param_line.strip().startswith("#"):
                            k += 1
                            continue
                        p_indent = len(param_line) - len(param_line.lstrip())
                        if params_indent is None:
                            params_indent = p_indent
                        if p_indent < params_indent:
                            break
                        if p_indent == params_indent:
                            key_m = re.match(r"\s*(\w+)\s*:", param_line)
                            if key_m:
                                params_found.append(key_m.group(1))
                        k += 1
                    j = k
                    break
                j += 1

            if params_found:
                calls.append({
                    "template": template_ref,
                    "params": params_found,
                    "line_no": line_no,
                })
        i += 1
    return calls


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def find_yaml_files(root: Path) -> list[Path]:
    results = []
    skip_dirs = {"V1", "V2", "Test", "Tests", ".github"}
    for p in sorted(root.rglob("*.yaml")) + sorted(root.rglob("*.yml")):
        if any(d in p.parts for d in skip_dirs):
            continue
        results.append(p)
    return results


def resolve_template_path(ref: str, source_file: Path, repo_root: Path) -> Path | None:
    """Risolve il path di un template. Ritorna None se è esterno (@alias)."""
    if "@" in ref:
        return None
    path_part = ref.split(" ")[0]
    if path_part.startswith("/"):
        return repo_root / path_part.lstrip("/")
    return (source_file.parent / path_part).resolve()


def main():
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent

    yaml_files = find_yaml_files(repo_root)
    errors = []
    checked_calls = 0

    print(f"Controllo contratti parametri in {len(yaml_files)} file YAML...\n")

    # Cache dei parametri definiti per evitare di rileggere lo stesso file
    defined_params_cache: dict[Path, set[str]] = {}

    for yaml_file in yaml_files:
        content = read_file(yaml_file)
        if content is None:
            continue

        calls = find_template_calls(content)
        for call in calls:
            ref = call["template"]
            resolved = resolve_template_path(ref, yaml_file, repo_root)
            if resolved is None:
                continue  # template esterno, skip

            if not resolved.exists():
                continue  # già segnalato da check-references.py

            checked_calls += 1

            # Leggi e cachea i parametri definiti nel template destinazione
            if resolved not in defined_params_cache:
                target_content = read_file(resolved)
                if target_content is None:
                    continue
                defined_params_cache[resolved] = extract_defined_params(target_content)

            defined = defined_params_cache[resolved]
            if not defined:
                # Il template non ha parametri definiti, skip (es. orchestratori con stepList)
                continue

            # Verifica: i parametri passati devono essere ⊆ parametri definiti
            passed = set(call["params"])
            unknown = passed - defined
            if unknown:
                rel_source = yaml_file.relative_to(repo_root)
                rel_target = resolved.relative_to(repo_root)
                errors.append(
                    f"  {rel_source}:{call['line_no']}\n"
                    f"    template: {ref}\n"
                    f"    Parametri sconosciuti: {sorted(unknown)}\n"
                    f"    Parametri accettati da {rel_target.name}: {sorted(defined)}"
                )

    print(f"Chiamate template con parametri controllate: {checked_calls}")
    print()

    if errors:
        print(f"[FAIL] {len(errors)} errore/i nei contratti parametri:\n")
        for err in errors:
            print(err)
            print()
        sys.exit(1)
    else:
        print(f"[PASS] Tutti i contratti parametri sono validi.")
        sys.exit(0)


if __name__ == "__main__":
    main()
