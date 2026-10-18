#!/usr/bin/env bash
# Falla si algún aprobador del despliegue es autor del cambio.
# "Prevent self-review" de GitHub solo impide aprobar a quien DISPARÓ la ejecución;
# aquí se compara contra los autores de los commits y del PR.
#
# Entorno: GH_TOKEN, GITHUB_REPOSITORY, RUN_ID, SHA, BEFORE (opcional)
set -euo pipefail

: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${RUN_ID:?}" "${SHA:?}"
BEFORE="${BEFORE:-}"
ZERO="0000000000000000000000000000000000000000"

approvers=$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}/approvals" \
  --jq '[.[] | select(.state == "approved") | .user.login] | unique | .[]')

if [ -z "$approvers" ]; then
  echo "::error::No hay aprobaciones registradas para esta ejecución; se bloquea el despliegue."
  exit 1
fi

authors=$(
  {
    if [ -n "$BEFORE" ] && [ "$BEFORE" != "$ZERO" ]; then
      gh api "repos/${GITHUB_REPOSITORY}/compare/${BEFORE}...${SHA}" \
        --jq '.commits[] | (.author.login // empty), (.committer.login // empty)'
    else
      gh api "repos/${GITHUB_REPOSITORY}/commits/${SHA}" \
        --jq '(.author.login // empty), (.committer.login // empty)'
    fi
    gh api "repos/${GITHUB_REPOSITORY}/commits/${SHA}/pulls" --jq '.[].user.login'
  } | grep -vx 'web-flow' | sort -u || true
)

echo "Aprobadores: $(echo "$approvers" | paste -sd, -)"
echo "Autores del cambio: $(echo "$authors" | paste -sd, -)"

conflict=$(comm -12 <(echo "$approvers" | sort -u) <(echo "$authors" | sort -u) || true)
if [ -n "$conflict" ]; then
  echo "::error::Separación de funciones violada: $(echo "$conflict" | paste -sd, -) aprobó un cambio del que es autor."
  exit 1
fi
echo "OK: ningún aprobador es autor del cambio."
