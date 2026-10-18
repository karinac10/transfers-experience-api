# transfers-experience-api

Capa de experiencia del sistema de transferencias interbancarias. Expone una API REST orientada al canal móvil, valida la entrada, traduce el modelo móvil ↔ BIAN y delega el procesamiento a **payment-order-process**.

---

## Endpoints

| Método | Ruta | Descripción |
|--------|------|-------------|
| `POST` | `/api/v1/transferencias` | Inicia una transferencia. Requiere `X-Idempotency-Key`. |
| `GET`  | `/api/v1/transferencias/{id}` | Consulta el estado de una transferencia por su ID. |

Puerto local: **8081**

---

## Arquitectura de tres capas

```
Cliente móvil
     │
     ▼
transfers-experience-api  :8081   ← este servicio
     │  BIAN PaymentOrderProcedure
     ▼
payment-order-process     :8082
     │  JSON interno
     ▼
core-transfers-system     :8083
```

---

## Decisiones de diseño

**Validación en dos niveles.** APIKit valida estructura y tipos contra el RAML (patrones, campos requeridos). Un módulo DataWeave (`validadorSolicitud.dwl`) valida semántica de negocio: `monto > 0`, `concepto ≤ 30 chars`, `fechaSolicitud` con timezone ISO 8601. Retorna `null` si todo es válido o un objeto de error detallado con la lista de campos inválidos.

**Idempotencia delegada a Process.** Experience solo verifica que `X-Idempotency-Key` esté presente y lo reenvía. La detección de replay y conflicto (409) ocurre en Process, que es quien tiene la información de las órdenes ya procesadas.

**Respuestas HTTP vía `vars.httpStatus`.** El código de estado se escribe en una variable dentro del flow; APIKit la lee al construir la respuesta. Esto permite manejar 201, 409 y 422 en el mismo sub-flow sin duplicar lógica.

**Error handler centralizado.** `common.xml` centraliza el mapeo de errores Mule a códigos semánticos BDA:

| Error Mule | HTTP | Código |
|---|---|---|
| `APP:MISSING_IDEMPOTENCY_KEY` | 400 | `VALIDACION_ERROR` |
| `APP:TRANSFER_NOT_FOUND` | 404 | `TRANSFERENCIA_NO_ENCONTRADA` |
| `HTTP:CONNECTIVITY` | 503 | `SERVICIO_NO_DISPONIBLE` |
| `HTTP:TIMEOUT` | 504 | `TIMEOUT` |

Todos los errores incluyen `correlationId` y `timestamp` para trazabilidad.

---

## Cómo ejecutar localmente

**Requisitos:** Mule 4.12.2 EE, Java 17, Maven 3.9.x. Iniciar primero `core-transfers-system` (:8083) y `payment-order-process` (:8082).

---

## Pipeline CI/CD

El pipeline compila una vez, publica una GitHub Release inmutable (`v1.0.N`) con SHA-256 y promueve el mismo `.jar` a dev → qa → prod. La cobertura MUnit debe ser ≥ 80 % para que el build pase. El despliegue a prod requiere aprobación manual de una persona distinta al autor del PR.
