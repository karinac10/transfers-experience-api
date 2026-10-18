#!/usr/bin/env bash
# Prueba de humo contra la Experience API recién desplegada. No crea transferencias.
#   1) Sin credenciales -> 401           (Client ID Enforcement activo)
#   2) Con credenciales, id inexistente -> 404 TRANSFERENCIA_NO_ENCONTRADA
#                                        (recorre Experience -> Process -> almacén)
#   3) Opcional (solo dev/qa): ráfaga -> debe aparecer algún 429 (Rate Limiting activo)
#
# Entorno: EXPERIENCE_URL (hasta /api, sin barra final), SMOKE_CLIENT_ID/SECRET,
#          RATE_LIMIT_PROBE_REQUESTS (opcional; vacío o 0 = omitir)
set -euo pipefail

if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "SIMULACIÓN: prueba de humo omitida (no hubo despliegue)."
  exit 0
fi

: "${EXPERIENCE_URL:?}" "${SMOKE_CLIENT_ID:?}" "${SMOKE_CLIENT_SECRET:?}"
base="${EXPERIENCE_URL%/}"
probe_url="$base/transferencias/00000000-0000-4000-8000-000000000000"

hdr="$(mktemp)"
chmod 600 "$hdr"
trap 'rm -f "$hdr"' EXIT
printf 'client_id: %s\nclient_secret: %s\n' "$SMOKE_CLIENT_ID" "$SMOKE_CLIENT_SECRET" > "$hdr"

fail() { echo "::error::Prueba de humo: $*"; exit 1; }

echo "Esperando a que la API responda..."
ready=0
for _ in $(seq 1 18); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$probe_url" || true)"
  if [ "$code" = "401" ] || [ "$code" = "404" ] || [ "$code" = "200" ]; then ready=1; break; fi
  sleep 10
done
[ "$ready" -eq 1 ] || fail "la API no respondió con un código esperado (último: $code)"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$probe_url")"
[ "$code" = "401" ] || fail "sin credenciales se esperaba 401 y respondió $code (¿Client ID Enforcement sin aplicar?)"
echo "OK  sin credenciales -> 401"

body="$(mktemp)"
code="$(curl -s -o "$body" -w '%{http_code}' --max-time 30 -H @"$hdr" "$probe_url")"
[ "$code" = "404" ] || { cat "$body"; rm -f "$body"; fail "con credenciales se esperaba 404 y respondió $code"; }
jq -e '.codigo == "TRANSFERENCIA_NO_ENCONTRADA" and (.correlationId | length > 0)' "$body" > /dev/null ||
  { cat "$body"; rm -f "$body"; fail "el 404 no tiene el formato ErrorResponse esperado"; }
rm -f "$body"
echo "OK  con credenciales, id inexistente -> 404 TRANSFERENCIA_NO_ENCONTRADA"

n="${RATE_LIMIT_PROBE_REQUESTS:-0}"
if [ "$n" -gt 0 ] 2> /dev/null; then
  hits="$(seq "$n" | xargs -P 20 -I{} curl -s -o /dev/null -w '%{http_code}\n' --max-time 20 -H @"$hdr" "$probe_url" | grep -c '^429$' || true)"
  [ "$hits" -gt 0 ] || fail "$n solicitudes seguidas y ningún 429 (¿Rate Limiting sin aplicar?)"
  echo "OK  ráfaga de $n solicitudes -> $hits respuestas 429"
else
  echo "--  prueba de ráfaga omitida"
fi
echo "Prueba de humo superada."
