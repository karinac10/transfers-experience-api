#!/usr/bin/env python3
"""Compuertas estáticas por proyecto Mule (corren en CI y antes de cada despliegue).

Convierte en código las lecciones del incidente INC-2026-118: ninguna de estas
reglas depende de que alguien recuerde revisarla.

Uso:
  validate_project.py <carpeta-proyecto> [--env dev|qa|prod] [--replicas N]
                      [--require-idempotency] [--allow-same clave1,clave2]
"""
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import yaml

# ── Convenciones del proyecto (ajústalas si tus claves se llaman distinto) ──
AUTODISCOVERY_KEY = "api.autodiscovery.apiId"
IDEMPOTENCY_KEY = "idempotency.enabled"
MIN_COVERAGE = 80
MIN_PROD_REPLICAS = 2
ENVS = ("dev", "qa", "prod")

ENV_FILE = re.compile(r"^(?:config[-_.]?)?(dev|qa|prod|local)\.ya?ml$", re.I)
SECRET_KEY = re.compile(r"(pass(word|wd)?|secret|token|api[-_]?key|private[-_]?key|credential)", re.I)
ENDPOINT_KEY = re.compile(r"(url|uri|host|endpoint|address)", re.I)
UNIQUE_KEY = re.compile(r"(url|uri|host|endpoint|address|apiid|api_id|instanceid)", re.I)
NONPROD_MARK = re.compile(r"(?<![a-z0-9])(qa|dev|test|uat|sandbox|stg|staging|localhost)(?![a-z0-9])", re.I)
PROD_MARK = re.compile(r"(?<![a-z0-9])prod(uction)?(?![a-z0-9])", re.I)

errors: list[str] = []


def err(msg: str, file: str | None = None) -> None:
    errors.append(msg)
    if os.environ.get("GITHUB_ACTIONS"):
        loc = f" file={file}" if file else ""
        print(f"::error{loc}::{msg}")
    else:
        print(f"ERROR {('[' + file + '] ') if file else ''}{msg}")


def flatten(node, prefix=""):
    out = {}
    if isinstance(node, dict):
        for k, v in node.items():
            out.update(flatten(v, f"{prefix}.{k}" if prefix else str(k)))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            out.update(flatten(v, f"{prefix}[{i}]"))
    else:
        out[prefix] = node
    return out


def is_placeholder(value) -> bool:
    s = str(value).strip()
    return s == "" or s.startswith("![") or s.startswith("${")


# ───────────────────────────── POM ─────────────────────────────
def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def descendants(el, name):
    return [e for e in el.iter() if local(e.tag) == name]


def text_of(el, name):
    for c in el:
        if local(c.tag) == name:
            return (c.text or "").strip()
    return None


def check_pom(project: Path) -> None:
    pom = project / "pom.xml"
    if not pom.exists():
        err("No existe pom.xml", str(project))
        return
    root = ET.parse(pom).getroot()
    plugins = descendants(root, "plugin")

    munit = [p for p in plugins if text_of(p, "artifactId") == "munit-maven-plugin"]
    if not munit:
        err("El pom no declara munit-maven-plugin: no hay compuerta de cobertura", str(pom))
    else:
        p = munit[0]
        cov = next(iter(descendants(p, "coverage")), None)
        if cov is None:
            err("munit-maven-plugin sin <coverage>", str(pom))
        else:
            if text_of(cov, "runCoverage") != "true":
                err("MUnit: runCoverage debe ser el literal true", str(pom))
            if text_of(cov, "failBuild") != "true":
                err("MUnit: failBuild debe ser el literal true (si no, la cobertura solo avisa)", str(pom))
            raw = text_of(cov, "requiredApplicationCoverage")
            if raw is None or not re.fullmatch(r"\d+", raw) or int(raw) < MIN_COVERAGE:
                err(f"MUnit: requiredApplicationCoverage debe ser un literal >= {MIN_COVERAGE} (hoy: {raw})", str(pom))
        goals = {g.text.strip() for g in descendants(p, "goal") if g.text}
        if "coverage-report" not in goals:
            err("MUnit: falta el goal coverage-report en las executions (sin él no se evalúa el umbral)", str(pom))

    for p in [p for p in plugins if text_of(p, "artifactId") == "mule-maven-plugin"]:
        for tag in ("password", "username", "authToken", "connectedAppClientId", "connectedAppClientSecret"):
            for el in descendants(p, tag):
                val = (el.text or "").strip()
                if val and not val.startswith("${"):
                    err(f"mule-maven-plugin: <{tag}> tiene un valor literal; debe venir de una propiedad", str(pom))
        for dep in descendants(p, "cloudhub2Deployment"):
            if text_of(dep, "muleVersion") in (None, ""):
                err("cloudhub2Deployment sin <muleVersion>: fija el runtime (evita 'runtime no soportado, fallback')", str(pom))


# ──────────────────────── Configuración por ambiente ────────────────────────
def discover_configs(project: Path) -> dict[str, tuple[Path, dict]]:
    found: dict[str, tuple[Path, dict]] = {}
    res = project / "src" / "main" / "resources"
    for path in sorted(res.rglob("*")) if res.exists() else []:
        m = ENV_FILE.match(path.name)
        if m and path.is_file():
            env = m.group(1).lower()
            data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            found[env] = (path, flatten(data))
    return found


def check_configs(project: Path, args) -> None:
    configs = discover_configs(project)
    for env in ENVS:
        if env not in configs:
            err(f"Falta el archivo de configuración del ambiente '{env}' (config-{env}.yaml)", str(project))
    if not configs:
        return

    allow_same = {k.strip() for k in (args.allow_same or "").split(",") if k.strip()}

    for env, (path, flat) in configs.items():
        for key, value in flat.items():
            last = key.split(".")[-1]
            # 1) Sin secretos en texto plano
            if SECRET_KEY.search(last) and not is_placeholder(value) and isinstance(value, str):
                err(f"Secreto en texto plano en '{key}'. Usa Secure Properties: ![valor cifrado]", str(path))
            # 2) Un ambiente no apunta a recursos de otro
            if isinstance(value, str) and (ENDPOINT_KEY.search(last) or "://" in value):
                if env == "prod" and NONPROD_MARK.search(value):
                    err(f"prod apunta a un recurso no productivo: {key} = {value}", str(path))
                if env in ("dev", "qa") and PROD_MARK.search(value):
                    err(f"{env} apunta a un recurso de producción: {key} = {value}", str(path))
            # 3) Réplicas mínimas si el archivo las declara
            if env == "prod" and last == "replicas":
                try:
                    if int(value) < MIN_PROD_REPLICAS:
                        err(f"prod con {value} réplica(s); mínimo {MIN_PROD_REPLICAS}", str(path))
                except (TypeError, ValueError):
                    err(f"replicas no numérico: {value}", str(path))

    # 4) Valores que deben ser distintos entre ambientes (url, host, apiId...)
    declared = [e for e in ENVS if e in configs]
    keys = {k for e in declared for k in configs[e][1] if UNIQUE_KEY.search(k.split(".")[-1])}
    for key in sorted(keys - allow_same):
        seen: dict[str, str] = {}
        for env in declared:
            value = configs[env][1].get(key)
            if value is None or str(value).strip() == "":
                continue
            if str(value) in seen:
                err(f"'{key}' idéntico en {seen[str(value)]} y {env} ({value}): ¿configuración copiada de otro ambiente?",
                    str(configs[env][0]))
            else:
                seen[str(value)] = env

    # 5) Autodiscovery obligatorio: cada ambiente gobernado por su propia instancia
    for env in declared:
        value = configs[env][1].get(AUTODISCOVERY_KEY)
        if value is None or str(value).strip() == "":
            err(f"Falta {AUTODISCOVERY_KEY} en {env}", str(configs[env][0]))

    # 6) Idempotencia obligatoria (solo en la capa que la implementa)
    if args.require_idempotency:
        for env in declared:
            value = configs[env][1].get(IDEMPOTENCY_KEY)
            if str(value).strip().lower() != "true":
                err(f"{IDEMPOTENCY_KEY} debe ser true en {env} (hoy: {value})", str(configs[env][0]))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("--env", choices=ENVS)
    ap.add_argument("--replicas")
    ap.add_argument("--require-idempotency", action="store_true")
    ap.add_argument("--allow-same", default="")
    args = ap.parse_args()

    project = Path(args.project)
    check_pom(project)
    check_configs(project, args)

    # 7) Réplicas del despliegue (variable del environment de GitHub)
    if args.env == "prod" and args.replicas is not None:
        try:
            if int(args.replicas) < MIN_PROD_REPLICAS:
                err(f"CH2_REPLICAS={args.replicas} en prod; mínimo {MIN_PROD_REPLICAS}")
        except ValueError:
            err(f"CH2_REPLICAS no es numérico: {args.replicas}")

    if errors:
        print(f"\n{len(errors)} problema(s) en {project}. Despliegue bloqueado.")
        return 1
    print(f"OK {project}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
