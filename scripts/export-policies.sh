#!/usr/bin/env bash
# Exporta las políticas YA aplicadas en una instancia de API Manager a JSON del repositorio.
# Úsalo una vez: configura las políticas a mano en dev, expórtalas y commitea el resultado.
# Así groupId, assetId, assetVersion y configurationData son exactamente los de tu tenant.
#
#   Uso:  export-policies.sh <system|process|experience> [directorio-salida]
#   Entorno: ANYPOINT_CLIENT_ID/SECRET, ANYPOINT_ORG_ID, ANYPOINT_ENVIRONMENT, API_INSTANCE_ID_<CAPA>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-anypoint.sh
source "$here/lib-anypoint.sh"

layer="${1:?Uso: export-policies.sh <system|process|experience> [directorio-salida]}"
out_dir="${2:-policies/$layer}"
: "${ANYPOINT_ORG_ID:?}" "${ANYPOINT_ENVIRONMENT:?}"
api_id="$(anypoint_layer_instance "$layer")"

anypoint_login
env_id="$(anypoint_env_id "$ANYPOINT_ORG_ID" "$ANYPOINT_ENVIRONMENT")"
url="$ANYPOINT_BASE/apimanager/api/v1/organizations/$ANYPOINT_ORG_ID/environments/$env_id/apis/$api_id/policies"
existing="$(anypoint_api GET "$url")"

mkdir -p "$out_dir"
jq -c 'if type == "array" then .[] else (.policies // .data // [])[] end' <<< "$existing" | while read -r p; do
  asset="$(jq -r '.assetId // .template.assetId // .policyTemplateId' <<< "$p")"
  jq '{
        configurationData,
        pointcutData: (.pointcutData // null),
        groupId: (.groupId // .template.groupId),
        assetId: (.assetId // .template.assetId),
        assetVersion: (.assetVersion // .template.assetVersion),
        order: (.order // 1)
      }' <<< "$p" > "$out_dir/$asset.json"
  echo "Exportada: $out_dir/$asset.json"
done
echo "Revisa los archivos. Si el rate limiting cambia por ambiente, renómbralo a rate-limiting.<env>.json."
