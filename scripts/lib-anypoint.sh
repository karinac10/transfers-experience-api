#!/usr/bin/env bash
# Funciones comunes para hablar con Anypoint usando una Connected App (client credentials).
# Los secretos nunca van en la línea de comandos: se leen de variables de entorno
# y los encabezados se pasan con "curl -H @archivo" (archivo 600 que se borra al salir).
# shellcheck shell=bash

ANYPOINT_BASE="${ANYPOINT_BASE:-https://anypoint.mulesoft.com}"
_HDR_FILE=""

# Siempre devuelve 0: si no, un 'exit 0' anterior a login terminaría con código 1.
_cleanup_hdr() {
  if [ -n "$_HDR_FILE" ]; then rm -f "$_HDR_FILE"; fi
  return 0
}
trap _cleanup_hdr EXIT

anypoint_login() {
  : "${ANYPOINT_CLIENT_ID:?}" "${ANYPOINT_CLIENT_SECRET:?}"
  local form token
  form=$(ID="$ANYPOINT_CLIENT_ID" SECRET="$ANYPOINT_CLIENT_SECRET" jq -rn \
    '"grant_type=client_credentials&client_id=\(env.ID | @uri)&client_secret=\(env.SECRET | @uri)"')
  token=$(printf '%s' "$form" | curl -fsS -X POST "$ANYPOINT_BASE/accounts/api/v2/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' --data @- | jq -er '.access_token')
  _HDR_FILE=$(mktemp)
  chmod 600 "$_HDR_FILE"
  printf 'Authorization: Bearer %s\n' "$token" > "$_HDR_FILE"
}

# anypoint_api METHOD URL [archivo-json]  -> imprime el cuerpo; falla si HTTP no es 2xx
anypoint_api() {
  local method="$1" url="$2" body="${3:-}" out code
  out=$(mktemp)
  if [ -n "$body" ]; then
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$url" \
      -H @"$_HDR_FILE" -H 'Content-Type: application/json' --data @"$body")
  else
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$url" -H @"$_HDR_FILE")
  fi
  if [[ "$code" != 2* ]]; then
    echo "::error::$method $url -> HTTP $code: $(head -c 400 "$out")" >&2
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
}

# anypoint_env_id ORG_ID NOMBRE_AMBIENTE -> imprime el id del ambiente
anypoint_env_id() {
  anypoint_api GET "$ANYPOINT_BASE/accounts/api/organizations/$1/environments" |
    jq -er --arg n "$2" '.data[] | select(.name == $n) | .id' | head -n1
}

# anypoint_layer_instance LAYER -> imprime el id de la instancia de API de esa capa
anypoint_layer_instance() {
  case "$1" in
    system) echo "${API_INSTANCE_ID_SYSTEM:?}" ;;
    process) echo "${API_INSTANCE_ID_PROCESS:?}" ;;
    experience) echo "${API_INSTANCE_ID_EXPERIENCE:?}" ;;
    *) echo "Capa desconocida: $1 (system|process|experience)" >&2; return 2 ;;
  esac
}
