#!/usr/bin/env bash
# Instala una versión FIJA de Maven y la pone primero en el PATH del job.
# Motivo: el mule-maven-plugin solo es compatible con ciertas versiones de Maven
# (la documentación del plugin 4.10.x indica 3.9.0 a 3.9.15). El Maven preinstalado en el
# runner de GitHub cambia con el tiempo y puede romper el build (NoSuchMethodError).
#   Uso: install-maven.sh            (versión por defecto: 3.9.9)
#        MAVEN_VERSION=3.9.11 install-maven.sh
set -euo pipefail

version="${MAVEN_VERSION:-3.9.9}"
base="${MAVEN_BASE_URL:-https://archive.apache.org/dist/maven/maven-3/${version}/binaries}"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
file="apache-maven-${version}-bin.tar.gz"

curl -fsSL --retry 3 -o "$tmp/$file" "$base/$file"
curl -fsSL --retry 3 -o "$tmp/$file.sha512" "$base/$file.sha512"
# El .sha512 de Apache trae solo el hash (a veces seguido del nombre del archivo)
expected="$(awk '{print $1}' "$tmp/$file.sha512" | head -n1)"
echo "${expected}  ${tmp}/${file}" | sha512sum -c -

tar -xzf "$tmp/$file" -C "$tmp"
bin="$tmp/apache-maven-${version}/bin"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$bin" >> "$GITHUB_PATH"; fi
export PATH="$bin:$PATH"
mvn -v
