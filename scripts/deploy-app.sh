#!/usr/bin/env bash
# Despliega UN proyecto a CloudHub 2.0 usando el .jar de la release (no recompila).
#   Uso: deploy-app.sh <carpeta-proyecto>
#
# Entorno: VERSION, ENVIRONMENT (dev|qa|prod), ANYPOINT_ENVIRONMENT, CH2_TARGET, CH2_REPLICAS,
#          CH2_VCORES, MULE_RUNTIME, ANYPOINT_CLIENT_ID/SECRET, MULE_KEY, EXCHANGE_PASSWORD,
#          SETTINGS (maven-settings.xml), SRC_DIR (código de la release), DIST_DIR (jars verificados)
set -euo pipefail

project="${1:?Uso: deploy-app.sh <carpeta-proyecto>}"
DRY_RUN="${DRY_RUN:-false}"   # true: verifica todo y muestra el plan, pero NO llama a Anypoint
: "${VERSION:?}" "${ENVIRONMENT:?}" "${SETTINGS:?}" "${SRC_DIR:?}" "${DIST_DIR:?}"
if [ "$DRY_RUN" != "true" ]; then
  : "${ANYPOINT_ENVIRONMENT:?}" "${CH2_TARGET:?}" "${CH2_REPLICAS:?}" "${CH2_VCORES:?}" "${MULE_RUNTIME:?}"
  : "${ANYPOINT_CLIENT_ID:?}" "${ANYPOINT_CLIENT_SECRET:?}" "${MULE_KEY:?}"
fi

mvn_q() { mvn -B -ntp -q -s "$SETTINGS" "$@"; }

cd "$SRC_DIR/$project"

# El pom del tag trae la versión de desarrollo; se alinea con la release solo para que
# el plugin encuentre el archivo (no cambia el contenido del .jar).
mvn_q org.codehaus.mojo:versions-maven-plugin:2.16.2:set -DnewVersion="$VERSION" -DgenerateBackupPoms=false
artifact_id="$(mvn_q help:evaluate -Dexpression=project.artifactId -DforceStdout)"
jar="${artifact_id}-${VERSION}-mule-application.jar"

[ -f "$DIST_DIR/$jar" ] || { echo "::error::La release v$VERSION no contiene $jar"; exit 1; }
mkdir -p target
cp "$DIST_DIR/$jar" "target/$jar"
sha="$(sha256sum "target/$jar" | cut -c1-16)"

if [ "$DRY_RUN" = "true" ]; then
  echo "SIMULACIÓN: el artefacto $jar (sha256 $sha) está verificado. Se ejecutaría 'mvn mule:deploy' como ${project}-${ENVIRONMENT}. No se llamó a Anypoint."
  exit 0
fi

echo "Desplegando $jar a $ANYPOINT_ENVIRONMENT/$CH2_TARGET como ${project}-${ENVIRONMENT} (sha256 $sha)"

# 'mule:deploy' despliega el artefacto existente en target/ SIN reconstruirlo.
# Los -D alimentan las propiedades ${...} del pom (ver pom-snippets.xml).
mvn -B -ntp -s "$SETTINGS" mule:deploy \
  -Dmule.env="$ENVIRONMENT" \
  -Dmule.key="$MULE_KEY" \
  -Dch2.environment="$ANYPOINT_ENVIRONMENT" \
  -Dch2.target="$CH2_TARGET" \
  -Dch2.appName="${project}-${ENVIRONMENT}" \
  -Dch2.replicas="$CH2_REPLICAS" \
  -Dch2.vcores="$CH2_VCORES" \
  -Dapp.runtime="$MULE_RUNTIME" \
  -Danypoint.connectedApp.id="$ANYPOINT_CLIENT_ID" \
  -Danypoint.connectedApp.secret="$ANYPOINT_CLIENT_SECRET"
