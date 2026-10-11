# Plan de pruebas end-to-end — AndesStay

> Pruebas de la cadena completa: navegador → Entra ID → API Gateway → nginx → BFF → microservicio
> → MySQL, con el flujo asíncrono de RabbitMQ en paralelo.
>
> Fecha: 2026-10-10 · Complementa a [Plan validacion RabbitMQ.md](Plan%20validacion%20RabbitMQ.md),
> que cubre en profundidad la capa de mensajería.

---

## 1. Cómo se usa este documento

Cada prueba tiene identificador, precondición, pasos, resultado esperado y evidencia. El
identificador es el que se cita en las capturas y en el checklist.

| Familia | Qué cubre | Dónde corre |
|---|---|---|
| `ID-*` | Identidad: login, PKCE, claims, roles | Navegador |
| `AZ-*` | Autorización: matriz de rol por ruta | curl o Postman |
| `RE-*` | Reservas: máquina de estados y reglas de negocio | Navegador y curl |
| `MQ-*` | Mensajería: colas, reintentos, DLQ, idempotencia | curl y Management UI |
| `GW-*` | API Gateway: rutas, CORS, authorizers | curl contra la nube |
| `RS-*` | Resiliencia: caídas, reinicios, durabilidad | docker |

Las pruebas `ID`, `AZ`, `RE` y `MQ` corren en local. Las `GW` solo tienen sentido contra el
despliegue en AWS.

---

## 2. Entorno de pruebas local

### 2.1 Qué hay que tener arriba

| Componente | Puerto | Cómo se levanta |
|---|---|---|
| RabbitMQ nodo 1 | 5672, UI 15672 | `docker compose --env-file .env -f infra/mq/compose.yml up -d rabbitmq1 rabbitmq2 rabbitmq-init` |
| RabbitMQ nodo 2 | 5673 | idem |
| MySQL | 3306 | `docker compose --env-file .env -f infra/deploy/compose.yml up -d mysql` |
| SMTP de prueba | 1025, UI 8025 | `docker run -d --name andesstay-mailpit -p 127.0.0.1:1025:1025 -p 127.0.0.1:8025:8025 axllent/mailpit` |
| ms-andesstay-catalog | 8082 | `mvn spring-boot:run` |
| ms-andesstay-reservations | 8081 | `mvn spring-boot:run` |
| ms-andesstay-bff | 8080 | `mvn spring-boot:run` |
| ms-andesstay-notify | 8085 | `mvn spring-boot:run` |
| frontend-andesstay | 4200 | `npm start` |

> El SMTP de prueba no es parte del sistema: reemplaza al servidor de correo real para que los
> envíos se puedan **ver** en lugar de deducirse del log, y para poder apagarlo a voluntad y
> provocar un fallo transitorio. En producción se usa el SMTP configurado por `MAIL_HOST`.

### 2.2 Comprobación previa

Ninguna prueba vale si esto no responde:

```bash
for p in 8080 8081 8082 8085; do curl -fsS http://127.0.0.1:$p/actuator/health; echo " <- $p"; done
```

Las cuatro respuestas tienen que ser `{"status":"UP"}`. Si `notify` no está `UP`, lo más probable
es que no alcance el broker: su health indicator de RabbitMQ está habilitado a propósito.

### 2.3 Datos de partida

Tres unidades sembradas, que son las que usan las pruebas:

| id | nombre | tipo | capacidad | tarifa/noche | cupos |
|---|---|---|---|---|---|
| 1 | Cabaña Coigüe | CABANA | 4 | 45 000 | 3 |
| 2 | Habitación Araucaria | HABITACION | 2 | 28 000 | 5 |
| 3 | Lodge Villarrica | LODGE | 8 | 120 000 | 1 |

El Lodge tiene **un solo cupo** a propósito: es la unidad con la que se prueban el agotamiento de
disponibilidad y la concurrencia.

### 2.4 Usuarios de prueba

Hace falta **un usuario por rol** en el tenant, con su App Role asignado:

| Rol (claim) | Para qué | Pruebas que lo usan |
|---|---|---|
| `Admin` | Administra unidades y ve KPIs | `AZ-*`, `RE-*` |
| `Operador` | Confirma, hace check-in y check-out | `RE-*` |
| `Cliente` | Crea y sigue sus reservas | `ID-03`, `AZ-*`, `RE-07` |
| `Auditor` | Solo lectura del timeline | `AZ-*` |

Un quinto usuario **sin ningún App Role asignado**, autoregistrado, sirve para `ID-04`.

---

## 3. ID — Identidad

### ID-01 · Login con Microsoft

| | |
|---|---|
| **Precondición** | Sesión del navegador limpia, o ventana privada |
| **Pasos** | Abrir `http://localhost:4200`, pulsar «Iniciar sesión con Microsoft», completar el login |
| **Esperado** | Vuelve a `/dashboard`. El nombre del usuario aparece en la cabecera. No hay errores en la consola |
| **Evidencia** | `id-01-dashboard.png` |

### ID-02 · Authorization Code con PKCE

| | |
|---|---|
| **Pasos** | Con las herramientas de desarrollo abiertas en la pestaña Red, repetir `ID-01` y buscar la petición a `login.microsoftonline.com/.../oauth2/v2.0/authorize` |
| **Esperado** | La URL lleva `code_challenge`, `code_challenge_method=S256`, `state` y `nonce`. En el intercambio posterior de `/token` viaja `code_verifier` y **no** hay `client_secret` |
| **Por qué importa** | Es el indicador 6 de la EP2, 15 %. Sin la captura no se puede evidenciar |
| **Evidencia** | `id-02-pkce.png` con los cuatro parámetros visibles |

### ID-03 · Roles leídos desde los claims

| | |
|---|---|
| **Pasos** | Autenticado, llamar `GET http://localhost:8080/api/me` con el token del navegador |
| **Esperado** | `200` con `effectiveRoles` conteniendo el rol asignado al usuario. La SPA muestra solo los menús de ese rol |
| **Comprobación cruzada** | Pegar el access token en jwt.ms y confirmar que `roles` trae el mismo valor, que `aud` es el client id y que `iss` termina en `/v2.0` |
| **Evidencia** | `id-03-me.png` y `id-03-token.png` |

### ID-04 · Huésped autoregistrado sin App Role

| | |
|---|---|
| **Precondición** | Usuario creado desde «Crear cuenta», sin App Role asignado |
| **Esperado** | `GET /api/me` devuelve `effectiveRoles: ["Cliente"]`, derivado por `AzureRolesConverter` a partir de `acct == 1` más el scope de la API |
| **Si falla** | El claim opcional `acct` no está en el access token. Se agrega en el portal: App registration → Token configuration → Add optional claim → Access → `acct`. No requiere redespliegue |
| **Evidencia** | `id-04-cliente-derivado.png` |

### ID-05 · Cierre de sesión

| | |
|---|---|
| **Esperado** | Vuelve a `/login`, y una navegación directa a `/dashboard` redirige al login en lugar de mostrar datos cacheados |

---

## 4. AZ — Autorización por rol

Matriz mínima. Por **cada fila** se prueban los tres casos: token con el rol correcto, sin cabecera
`Authorization`, y token con un rol insuficiente.

| # | Método y ruta | 200 para | 403 para |
|---|---|---|---|
| AZ-01 | `GET /api/me` | cualquier autenticado | — |
| AZ-02 | `POST /api/reservations` | Admin, Operador, Cliente | Auditor |
| AZ-03 | `GET /api/reservations` | Admin, Operador | Cliente, Auditor |
| AZ-04 | `GET /api/reservations/{id}` | Admin, Operador, Auditor, y el Cliente dueño | Cliente no dueño |
| AZ-05 | `PUT /api/reservations/{id}/status` | Admin, Operador | Cliente, Auditor |
| AZ-06 | `GET /api/catalog/units` | Admin, Operador | Cliente, Auditor |
| AZ-07 | `POST /api/catalog/units` | Admin | Operador, Cliente, Auditor |
| AZ-08 | `PUT /api/catalog/units/{id}` | Admin | Operador, Cliente, Auditor |
| AZ-09 | `DELETE /api/catalog/units/{id}` | Admin | el resto |
| AZ-10 | `GET /api/report/kpis` | Admin | Operador, Cliente, Auditor |
| AZ-11 | `GET /api/report/top-units` | Admin | el resto |
| AZ-12 | `GET /api/audit/events` | Admin, Auditor | Operador, Cliente |
| AZ-13 | `GET /api/audit/reservations/{id}/timeline` | Admin, Auditor | Operador, Cliente |
| AZ-14 | `PATCH /api/catalog/internal/units/{id}/slots` | **nadie** por el BFF: `denyAll` | todos |

Sin token, **todas** devuelven `401`, no `403`. La diferencia importa: `401` significa «no sé quién
eres» y `403` «sé quién eres y no te alcanza». Son códigos distintos y la rúbrica los evalúa.

Script de la batería:

```bash
TOKEN="<access token del rol a probar>"
for r in /api/me /api/reservations /api/catalog/units /api/report/kpis /api/audit/events; do
  printf "%-32s con=%s sin=%s\n" "$r" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080$r)" \
    "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080$r)"
done
```

**Evidencia**: `az-matriz.png` con la salida del script por cada rol, y la colección de Postman
versionada en `infra/docs/evidencias/`.

---

## 5. RE — Reservas: máquina de estados y reglas

La referencia es [`infra/docs/contracts/estados.md`](../infra/docs/contracts/estados.md).

### RE-01 · Ruta feliz completa

El caso central. Se ejecuta **desde la interfaz**, no con curl, porque es el que demuestra que
frontend y backend se comunican.

| Paso | Actor | Acción | Esperado en pantalla | Esperado detrás |
|---|---|---|---|---|
| 1 | Cliente | Crear reserva de la unidad 1, 3 noches | La reserva aparece en `CREADA` | Fila en `reservations` con `correlation_id` asignado; mensaje `email.send` con plantilla `RESERVA_RECIBIDA` |
| 2 | Operador | Confirmar | Pasa a `CONFIRMADA` | `available_slots` de la unidad 1 baja de 3 a 2; llegan `email.send` (`RESERVA_CONFIRMADA`) y `voucher.gen` |
| 3 | Operador | Marcar check-in pendiente | Pasa a `CHECKIN_PENDIENTE` | `housekeeping.ticket` con `tipoTarea=PREPARACION` y `prioridad=ALTA`; `email.send` (`RECORDATORIO_CHECKIN`) |
| 4 | Operador | Marcar en estadía | Pasa a `EN_ESTADIA` | Sin mensajes |
| 5 | Operador | Hacer check-out | Pasa a `CHECKOUT` | `available_slots` vuelve a 3; `housekeeping.ticket` con `tipoTarea=LIMPIEZA`; `email.send` (`CHECKOUT_REALIZADO`) |

Comprobación del lado de los datos en cada paso:

```bash
docker exec andesstay-mysql-demo mysql -uandesstay -p<clave> andesstay \
  -e "SELECT id,status,unit_id,total_price,correlation_id FROM reservations ORDER BY id DESC LIMIT 5;
      SELECT id,name,available_slots FROM catalog_units;"
```

Comprobación del lado de los mensajes: los correos en `http://localhost:8025` y los tickets en el
log de `notify`.

**Todos los mensajes de la misma reserva comparten `correlationId`.** Es lo que permite armar su
timeline filtrando por un solo campo, y conviene mostrarlo en la evidencia.

**Evidencia**: `re-01-a.png` … `re-01-e.png`, una por estado, más `re-01-buzon.png`.

### RE-02 · No hay check-in sin confirmar

| | |
|---|---|
| **Pasos** | Sobre una reserva en `CREADA`, pedir `CHECKIN_PENDIENTE` |
| **Esperado** | `409` con `{"error":"TRANSICION_INVALIDA","desde":"CREADA","hacia":"CHECKIN_PENDIENTE"}` y la reserva **sigue** en `CREADA` |
| **Regla** | Es la regla explícita del caso |

### RE-03 · Saltarse estados

Pedir `EN_ESTADIA` desde `CREADA`: `409`. Pedir cualquier estado desde `CHECKOUT` o desde
`CANCELADA`: `409`, porque los dos son terminales.

### RE-04 · Confirmar sin cupo

| | |
|---|---|
| **Precondición** | Unidad 3, Lodge Villarrica, con un solo cupo, ya consumido por otra reserva confirmada |
| **Esperado** | `409` con `{"error":"SIN_DISPONIBILIDAD","unitId":3}` y la reserva **permanece en `CREADA`** |
| **Por qué importa** | Es la regla que resuelve el overbooking del caso, que es el problema de negocio de partida |

### RE-05 · Fechas solapadas

Crear dos reservas de la misma unidad con rangos que se cruzan: la segunda falla. Importa el caso
límite: `checkOut` de una igual a `checkIn` de la otra **no** se solapa y debe aceptarse.

### RE-06 · Cancelación restituye el cupo

| | |
|---|---|
| **Pasos** | Confirmar una reserva, anotar `available_slots`, cancelarla |
| **Esperado** | El cupo vuelve a su valor anterior y llega `email.send` con `RESERVA_CANCELADA` |
| **Ojo** | Este caso detectó un defecto real: la comparación del estado anterior se hacía sobre la entidad ya mutada, así que el cupo nunca se restituía. Conviene no quitarlo de la batería |

### RE-07 · Un huésped solo opera lo suyo

| | |
|---|---|
| **Pasos** | Con token de `Cliente` A, pedir `GET /api/reservations/{id}` de una reserva de `Cliente` B |
| **Esperado** | `403` |
| **Y además** | El mismo `Cliente` A **sí** puede ver la suya, y puede cancelarla mientras esté en `CREADA` |

### RE-08 · Capacidad y total

| | |
|---|---|
| **Pasos** | Reservar la unidad 2, capacidad 2, para 3 huéspedes |
| **Esperado** | `400` |
| **Y además** | Una reserva de 3 noches en la unidad 1 a 45 000 deja `total_price = 135000` |

### RE-09 · Concurrencia sobre la última plaza

| | |
|---|---|
| **Pasos** | Dos confirmaciones simultáneas sobre el único cupo del Lodge |
| **Esperado** | Una `200` y la otra `409`. Nunca dos `200` |
| **Comando** | `seq 2 \| xargs -P2 -I{} curl -s -o /dev/null -w "%{http_code}\n" -X PUT ... ` |

---

## 6. MQ — Mensajería

El detalle está en [Plan validacion RabbitMQ.md](Plan%20validacion%20RabbitMQ.md), sección 9. Aquí
quedan los identificadores para trazar la evidencia.

| # | Prueba | Esperado |
|---|---|---|
| MQ-01 | Confirmar una reserva | Mensajes en `q.cmd.email` y `q.cmd.voucher`, consumidos |
| MQ-02 | Publicar con plantilla inexistente | A la DLQ **sin** reintentos, `x-death` con `reason=rejected` |
| MQ-03 | Publicar un cuerpo que no es JSON | Igual que MQ-02: error permanente |
| MQ-04 | Apagar el SMTP y publicar | **Tres** intentos con backoff 1 s, 2 s y 4 s, y recién entonces la DLQ |
| MQ-05 | Publicar dos veces el mismo `eventId` | Se procesa una sola vez |
| MQ-06 | Detener `notify`, publicar, reiniciar | Los mensajes se acumulan y se procesan al volver |
| MQ-07 | Reiniciar el broker con mensajes encolados | Sobreviven: cola durable más mensaje persistente |
| MQ-08 | Publicar con una routing key sin binding | El `ReturnsCallback` lo registra en `reservations` |
| MQ-09 | `GET /actuator/metrics/notify.messages.dlq` | Contador por cola |
| MQ-10 | `GET /api/v1/notify/status` | Profundidad de las seis colas |
| MQ-11 | Apagar `rabbitmq1` y publicar contra `rabbitmq2` | Las colas siguen disponibles, por la política de espejado |
| MQ-12 | Dejar un mensaje más de 5 min sin consumir | Expira por `x-message-ttl`, `x-death` con `reason=expired` |

**MQ-04 es el criterio de cierre de la fase 6.** Es el único que demuestra que el reintento existe;
los demás pasan igual con reintentos rotos.

---

## 7. RS — Resiliencia

| # | Prueba | Esperado |
|---|---|---|
| RS-01 | Detener MySQL y crear una reserva | `503` o `500` con mensaje claro. Al volver MySQL, el servicio se recupera sin reinicio |
| RS-02 | Detener el broker con `ANDESSTAY_EVENTS_RABBIT_ENABLED=true` | Los `POST` fallan: `convertAndSend` es síncrono. Es el motivo de que la bandera exista |
| RS-03 | Detener el broker con la bandera en `false` | Las reservas se crean con normalidad y las publicaciones se omiten |
| RS-04 | Detener `catalog` y confirmar una reserva | Hoy el fallo se traga y la disponibilidad queda inconsistente. **Tras el bloque E debe devolver `409`** |
| RS-05 | Reiniciar `notify` | Vuelve a declarar la topología sin error y retoma el consumo |

RS-04 es el que cambia de comportamiento con el bloque E: hoy documenta un defecto conocido, después
documenta la corrección.

---

## 8. GW — API Gateway (solo contra AWS)

| # | Prueba | Esperado |
|---|---|---|
| GW-01 | Las 16 rutas de contrato, sin `Authorization` | `401` del gateway |
| GW-02 | Las 16 rutas con rol correcto | `200` y el JSON esperado |
| GW-03 | Las 16 rutas con rol insuficiente | `403` del BFF |
| GW-04 | Token con `aud` de otra aplicación | `401` del gateway |
| GW-05 | `curl` directo al puerto 80 sin `X-Gateway-Secret` | `403` de nginx, sin llegar al BFF |
| GW-06 | Ruta no declarada | `404` del gateway, sin `$default` abierto |
| GW-07 | `OPTIONS` de preflight desde el origen del frontend | `204` con las cabeceras exactas, sin comodines |
| GW-08 | `OPTIONS` desde un origen no listado | Sin cabecera `Access-Control-Allow-Origin` |
| GW-09 | Auditoría: ninguna ruta con `AuthorizationType = NONE` | El guard del script lo verifica y falla el despliegue si ocurre |

Tras el versionado se agregan:

| # | Prueba | Esperado |
|---|---|---|
| GW-10 | `GET /staff/v1/reservations` | Funciona |
| GW-11 | `GET /staff/reservations`, sin versión, retirado el shim | `404` |
| GW-12 | Token sin el scope exigido por la ruta | `401` del gateway |
| GW-13 | `/actuator/health` de cada contenedor | `200 UP`: el prefijo de versión no afecta a Actuator |

---

## 9. Orden de ejecución sugerido

```
ID-01 → ID-03          abre la sesión y confirma el rol
  └─ AZ-*              la matriz, con el token recién obtenido
       └─ RE-01        la ruta feliz, desde la interfaz
            └─ MQ-01   comprueba el reflejo asíncrono
  RE-02 … RE-09        reglas de negocio
  MQ-02 … MQ-12        mensajería
  RS-*                 resiliencia, al final: deja servicios caídos
```

`RS-*` va último a propósito: apaga cosas y deja el entorno sucio.

---

## 10. Trazabilidad con las rúbricas

| Indicador | Peso | Pruebas que lo evidencian |
|---|---|---|
| EP1-1 · MSAL en Angular, roles desde los claims | 60 % | `ID-01`, `ID-02`, `ID-03`, `ID-04` |
| EP1-2 · El BFF valida el token, códigos adecuados | 40 % | `AZ-*` completo, `GW-04` |
| EP2-1 · Rutas del API Manager | 13 % | `GW-01`, `GW-02`, `GW-10` |
| EP2-2 · CORS sin sobrepermisos | 7 % | `GW-07`, `GW-08` |
| EP2-5 · Flujo de autorregistro | 10 % | `ID-04` |
| EP2-6 · Authorization Code con PKCE | 15 % | `ID-02` |
| EP2-7 · Todas las rutas validan JWT | 20 % | `GW-01`, `GW-09`, `GW-12` |
| EP2-8 · Evidencia por ruta, con y sin token | 15 % | `AZ-*`, `GW-01` a `GW-03` |
| Caso · Reservas y máquina de estados | — | `RE-*` |
| Caso · RabbitMQ con DLQ | — | `MQ-*`, fase 6 |

---

## 11. Evidencia

Todo va a `infra/docs/evidencias/`, en subcarpetas por familia:

```
infra/docs/evidencias/
├── identidad/      ID-*
├── autorizacion/   AZ-*  + coleccion-postman.json
├── reservas/       RE-*
├── rabbitmq/       MQ-*
├── resiliencia/    RS-*
└── cors/           GW-07, GW-08
```

Cada captura lleva el identificador de la prueba en el nombre. Una captura sin identificador no
sirve como evidencia, porque no se puede decir qué prueba.
