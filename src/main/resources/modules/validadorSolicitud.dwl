%dw 2.0

fun campoVacio(valor) =
    valor == null or
    ((valor is String) and trim(valor) == "")

fun validarSolicitud(solicitud, transactionId = "") =
    do {
        var errores =
            (if (campoVacio(solicitud.cuentaOrigen default null))
                ["El campo cuentaOrigen es obligatorio."]
             else if (
                not ((solicitud.cuentaOrigen) matches /^[0-9]{6,20}$/)
             )
                ["El campo cuentaOrigen debe contener entre 6 y 20 dígitos numéricos."]
             else [])

            ++
            (if (campoVacio(solicitud.cuentaDestino default null))
                ["El campo cuentaDestino es obligatorio."]
             else if (
                not ((solicitud.cuentaDestino) matches /^[0-9]{6,20}$/)
             )
                ["El campo cuentaDestino debe contener entre 6 y 20 dígitos numéricos."]
             else [])

            ++
            (if (campoVacio(solicitud.bancoDestino default null))
                ["El campo bancoDestino es obligatorio."]
             else if (
                not ((solicitud.bancoDestino) matches /^[A-Z]{3}-[0-9]{4}$/)
             )
                ["El campo bancoDestino debe cumplir el formato AAA-0000."]
             else [])

            ++
            (if (solicitud.monto == null)
                ["El campo monto es obligatorio."]
             else if (not (solicitud.monto is Number))
                ["El campo monto debe ser numérico."]
             else if (solicitud.monto <= 0)
                ["El campo monto debe ser mayor que cero."]
             else [])

            ++
            (if (campoVacio(solicitud.moneda default null))
                ["El campo moneda es obligatorio."]
             else [])

            ++
            (if (campoVacio(solicitud.concepto default null))
                ["El campo concepto es obligatorio."]
             else if (sizeOf(solicitud.concepto as String) > 30)
                ["El campo concepto no puede exceder 30 caracteres."]
             else [])

            ++
            (if (campoVacio(solicitud.fechaSolicitud default null))
                ["El campo fechaSolicitud es obligatorio."]
             else if (not ((solicitud.fechaSolicitud as String) matches /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}([+-]\d{2}:\d{2}|Z)$/))
                ["El campo fechaSolicitud debe estar en formato ISO 8601 con timezone: yyyy-MM-ddTHH:mm:ss±HH:MM o Z."]
             else [])
        ---
        if (isEmpty(errores))
            null
        else
            {
                codigo: "VALIDACION_ERROR",
                mensaje: "La solicitud contiene datos inválidos.",
                description: errores,
                correlationId: transactionId default "",
                timestamp: now() as String {
                    format: "yyyy-MM-dd'T'HH:mm:ssXXX"
                }
            }
    }
