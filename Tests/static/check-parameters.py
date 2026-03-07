#!/usr/bin/env python3
"""
check-parameters.py

Verifica i contratti parametri tra file YAML nella libreria V3:
per ogni coppia (template: X, parameters: {...}), controlla che:
  1. Tutti i nomi di parametro PASSATI esistano nella definizione di X (nessun typo)
  2. Tutti i parametri OBBLIGATORI di X (senza 'default:') siano passati dal caller

Regole:
- Scansiona solo V3/ (V1, V2, Test, Tests esclusi)
- Ignora riferimenti con '@repoAlias' (template da repo esterni)
- Exit 1 se almeno un errore viene rilevato
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


def extract_defined_params(content: str) -> tuple[set[str], set[str]]:
    """
    Estrae i parametri dalla sezione top-level 'parameters:' di un template.

    Ritorna (all_params, required_params):
    - all_params     : tutti i nomi definiti
    - required_params: nomi privi di 'default:' nel loro blocco (parametri obbligatori)
    """
    all_params: set[str] = set()
    required_params: set[str] = set()

    in_params = False
    current_name: str | None = None
    has_default = False

    for line in content.splitlines():
        stripped = line.strip()

        if re.match(r"^parameters\s*:", stripped):
            in_params = True
            continue

        if in_params:
            # Fine blocco parameters: chiave top-level senza indentazione
            if stripped and not stripped.startswith("-") and not stripped.startswith("#"):
                if not line.startswith(" ") and not line.startswith("\t"):
                    if current_name is not None:
                        all_params.add(current_name)
                        if not has_default:
                            required_params.add(current_name)
                    in_params = False
                    continue

            m = re.match(r"-\s*name\s*:\s*(\S+)", stripped)
            if m:
                # Salva il parametro precedente
                if current_name is not None:
                    all_params.add(current_name)
                    if not has_default:
                        required_params.add(current_name)
                current_name = m.group(1).strip("'\"")
                has_default = False
            elif current_name and re.match(r"default\s*:", stripped):
                has_default = True

    # Ultimo parametro del file
    if in_params and current_name is not None:
        all_params.add(current_name)
        if not has_default:
            required_params.add(current_name)

    return all_params, required_params


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
    # Valore: (all_params, required_params)
    defined_params_cache: dict[Path, tuple[set[str], set[str]]] = {}

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

            all_defined, required = defined_params_cache[resolved]
            if not all_defined:
                # Il template non ha parametri definiti, skip
                continue

            passed = set(call["params"])
            rel_source = yaml_file.relative_to(repo_root)
            rel_target = resolved.relative_to(repo_root)

            # Check 1: parametri passati ⊆ definiti (nessun typo / param rinominato)
            unknown = passed - all_defined
            if unknown:
                errors.append(
                    f"  {rel_source}:{call['line_no']}\n"
                    f"    template: {ref}\n"
                    f"    Parametri sconosciuti: {sorted(unknown)}\n"
                    f"    Parametri accettati da {rel_target.name}: {sorted(all_defined)}"
                )

            # Check 2: parametri obbligatori (senza default) devono essere passati
            missing_required = required - passed
            if missing_required:
                errors.append(
                    f"  {rel_source}:{call['line_no']}\n"
                    f"    template: {ref}\n"
                    f"    Parametri obbligatori non passati: {sorted(missing_required)}\n"
                    f"    (parametri senza 'default:' in {rel_target.name})"
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
        print("[PASS] Tutti i contratti parametri sono validi (nessun param sconosciuto, nessun required mancante).")
        sys.exit(0)


if __name__ == "__main__":
    main()
