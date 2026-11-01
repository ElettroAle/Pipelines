# SPDX-License-Identifier: Apache-2.0

# Attesa prima di ripetere una richiesta al modello linguistico rifiutata per un errore transitorio. Il
# limite di token al minuto di Azure OpenAI risponde 429 e dice in Retry-After quanto aspettare: un'attesa
# piu' breve torna 429. Senza Retry-After l'attesa raddoppia a ogni tentativo, fino a un minuto.

$ModelMaxAttempts = 10

function Get-ModelRetryDelay($Response, [int]$Attempt) {
    $delta = $Response.Headers.RetryAfter.Delta
    if ($delta) { return [math]::Ceiling($delta.TotalSeconds) }
    return [math]::Min(60, [math]::Pow(2, $Attempt))
}
