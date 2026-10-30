# CLAUDE.md

## Licenza e header SPDX

Il repository è distribuito con licenza Apache 2.0 (`LICENSE`, `NOTICE`). Ogni file sorgente di
`V3/` e `V4/` apre con l'header SPDX della licenza:

- `# SPDX-License-Identifier: Apache-2.0` in `.yaml`, `.yml`, `.ps1`, `.psd1`, `.toml`
- `// SPDX-License-Identifier: Apache-2.0` in `.mjs`, `.cs` (nei `.cs` dopo le direttive `#:`)

L'header è la prima riga del file, seguita da una riga vuota. Ogni file nuovo nasce con l'header:
`Tests/Static/check-spdx.py` lo verifica nel workflow Static Analysis e fa fallire la build se manca.
`LICENSE` resta identico al testo ufficiale e non si modifica.

## Identità dei commit

I commit su questo repository usano l'autore `Alessandro Fiani <fiani.alessandro@gmail.com>`, mai
l'email aziendale: il repository è personale. Prima di fare commit si verifica `git config user.email`.
