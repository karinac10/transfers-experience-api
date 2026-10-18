#!/usr/bin/env bash
# Políticas de API Manager como código (idempotente).
#   Uso:  apply-policies.sh <system|process|experience>
#   Lee:  $POLICIES_DIR/<capa>/*.json  (los *.dev|qa|prod.json solo aplican a ese ambiente)
#   Crea la política si no existe y actualiza su configuración si ya existe.
#   Avisa (no borra) de políticas aplicadas en la API que no están en el repositorio.
#
# Entorno: ANYPOINT_CLIENT_ID/SECRET, ANYPOINT_ORG_ID, ANYPOINT_ENVIRONMENT, ENVIRONMENT,
#          API_INSTANCE_ID_<CAPA>, POLICIES_DIR (por defecto ./policies)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-anypoint.sh
source "$here/lib-anypoint.sh"

layer="${1:?Uso: apply-policies.sh <system|process|experience>}"
DRY_RUN="${DRY_RUN:-false}"   # true: valida y muestra el plan, pero NO llama a Anypoint
: "${ENVIRONMENT:?}"
dir="${POLICIES_DIR:-policies}/$layer"

shopt -s nullglob
files=()
for f in "$dir"/*.json; do
  name="$(basename "$f" .json)"
  case "$name" in
    *.dev | *.qa | *.prod) [ "${name##*.}" = "$ENVIRONMENT" ] || continue ;;
  esac
  files+=("$f")
done
[ "${#files[@]}" -gt 0 ] || { echo "::error::No hay políticas para '$layer' en $dir"; exit 1; }

for f in "${files[@]}"; do
  if grep -q 'REPLACE' "$f"; then
    if [ "$DRY_RUN" = "true" ]; then
      echo "::warning file=$f::Plantilla sin completar (contiene REPLACE...). Debe completarse antes de pasar a producción real."
    else
      echo "::error file=$f::Plantilla sin completar (contiene REPLACE...). Expórtala con scripts/export-policies.sh."
      exit 1
    fi
  fi
  jq -e '.assetId and .assetVersion and .groupId and .configurationData' "$f" > /dev/null ||
    { echo "::error file=$f::Faltan campos (groupId, assetId, assetVersion, configurationData)"; exit 1; }
done

if [ "$DRY_RUN" = "true" ]; then
  for f in "${files[@]}"; do
    echo "SIMULACIÓN: se aplicaría $layer/$(jq -r '.assetId' "$f") en $ENVIRONMENT ($(basename "$f"))"
  done
  exit 0
fi

: "${ANYPOINT_ORG_ID:?}" "${ANYPOINT_ENVIRONMENT:?}"
api_id="$(anypoint_layer_instance "$layer")"

anypoint_login
env_id="$(anypoint_env_id "$ANYPOINT_ORG_ID" "$ANYPOINT_ENVIRONMENT")"
[ -n "$env_id" ] || { echo "::error::No se encontró el ambiente '$ANYPOINT_ENVIRONMENT'"; exit 1; }

url="$ANYPOINT_BASE/apimanager/api/v1/organizations/$ANYPOINT_ORG_ID/environments/$env_id/apis/$api_id/policies"
existing="$(anypoint_api GET "$url")"

policy_list='if type == "array" then . else (.policies // .data // []) end'
declared=()
for f in "${files[@]}"; do
  asset="$(jq -r '.assetId' "$f")"
  declared+=("$asset")
  policy_id="$(jq -r --arg a "$asset" "[ ($policy_list)[]
      | select((.assetId // .template.assetId // .policyTemplateId // \"\") == \$a)
      | (.policyId // .id) | tostring ] | first // empty" <<< "$existing")"
  if [ -n "$policy_id" ]; then
    tmp="$(mktemp)"
    jq '{configurationData, pointcutData, order}' "$f" > "$tmp"
    anypoint_api PATCH "$url/$policy_id" "$tmp" > /dev/null
    rm -f "$tmp"
    echo "Actualizada: $layer/$asset ($ENVIRONMENT, instancia $api_id)"
  else
    tmp="$(mktemp)"
    jq 'del(._comment)' "$f" > "$tmp"
    anypoint_api POST "$url" "$tmp" > /dev/null
    rm -f "$tmp"
    echo "Creada:      $layer/$asset ($ENVIRONMENT, instancia $api_id)"
  fi
done

# Deriva: políticas aplicadas en la API que el repositorio no declara
while IFS= read -r applied; do
  [ -z "$applied" ] && continue
  printf '%s\n' "${declared[@]}" | grep -qx "$applied" ||
    echo "::warning::Deriva: '$applied' está aplicada en $layer ($ENVIRONMENT) pero no está en el repositorio."
done < <(jq -r "($policy_list)[] | (.assetId // .template.assetId // .policyTemplateId // empty)" <<< "$existing")
