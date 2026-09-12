# Contrato — Rutas del API Gateway

Contrato canónico del **API Manager**. Es la base de los indicadores 1 (rutas, 13%), 2 (CORS, 7%)
y 7 (validación JWT en todas las rutas, 20%) de la EP2.

## Tipo de API

**HTTP API** de AWS API Gateway, no REST API. El JWT Authorizer nativo, que es lo que evalúa el
indicador 7, pertenece a HTTP API.

## Por qué las rutas se parten en `/staff` y `/guest`

El personal y los huéspedes usan **app registrations distintas**, y por lo tanto **audiences
distintas**. Con dos authorizers y las rutas separadas por audiencia, cada ruta queda asociada
a la aplicación que le corresponde, y queda visible en la consola que todas validan issuer y
audience.

Ambas aplicaciones viven en el **mismo tenant**, así que los dos authorizers comparten issuer y
se diferencian solo por la audience. La separación sigue siendo efectiva: un token emitido para
la aplicación de huéspedes tiene `aud` de esa app y el authorizer de `/staff/*` lo rechaza.

## Authorizers

| Nombre | Issuer | Audience | Scope requerido |
|---|---|---|---|
| `entra-staff` | `https://login.microsoftonline.com/<staff-tenant-id>/v2.0` | `api://<staff-client-id>` | `access_as_staff` |
| `entra-guest` | `https://login.microsoftonline.com/<tenant-id>/v2.0` *(el mismo)* | `api://<guest-client-id>` | `access_as_guest` |

Los valores reales se registran en `infra/docs/idaas/` y **no se versionan** los secretos.

## Tabla de rutas

Todas las rutas integran contra el mismo backend: `ms-andesstay-bff` en `ec2-apps`.

| # | Método | Ruta en el gateway | Authorizer | Destino en el BFF | Roles |
|---|---|---|---|---|---|
| 1 | `POST` | `/guest/reservations` | `entra-guest` | `POST /api/reservations` | Huésped |
| 2 | `GET` | `/guest/reservations` | `entra-guest` | `GET /api/reservations` | Huésped |
| 3 | `GET` | `/guest/reservations/{id}` | `entra-guest` | `GET /api/reservations/{id}` | Huésped |
| 4 | `PUT` | `/guest/reservations/{id}/status` | `entra-guest` | `PUT /api/reservations/{id}/status` | Huésped, solo cancelar |
| 5 | `GET` | `/guest/catalog/units` | `entra-guest` | `GET /api/catalog/units` | Huésped |
| 6 | `POST` | `/staff/reservations` | `entra-staff` | `POST /api/reservations` | Recepcionista |
| 7 | `GET` | `/staff/reservations` | `entra-staff` | `GET /api/reservations` | Admin, Recepcionista |
| 8 | `GET` | `/staff/reservations/{id}` | `entra-staff` | `GET /api/reservations/{id}` | Admin, Recepcionista |
| 9 | `PUT` | `/staff/reservations/{id}/status` | `entra-staff` | `PUT /api/reservations/{id}/status` | Admin, Recepcionista |
| 10 | `GET` | `/staff/catalog/units` | `entra-staff` | `GET /api/catalog/units` | Admin, Recepcionista |
| 11 | `POST` | `/staff/catalog/units` | `entra-staff` | `POST /api/catalog/units` | Admin |
| 12 | `PUT` | `/staff/catalog/units/{id}` | `entra-staff` | `PUT /api/catalog/units/{id}` | Admin |
| 13 | `GET` | `/staff/report/kpis` | `entra-staff` | `GET /api/report/kpis` | Admin |
| 14 | `GET` | `/staff/report/top-units` | `entra-staff` | `GET /api/report/top-units` | Admin |
| 15 | `GET` | `/staff/audit` | `entra-staff` | `GET /api/audit` | Admin, Auditor |
| 16 | `GET` | `/staff/audit/{reservationId}` | `entra-staff` | `GET /api/audit/{reservationId}` | Admin, Auditor |

**Las 16 rutas llevan authorizer. Ninguna queda abierta.** No existe ruta `$default` sin
proteger: una petición a un path no declarado devuelve `404` del gateway.

Los endpoints internos `hold` y `release` de catalog **no se publican en el gateway**: solo los
llama `ms-andesstay-reservations` dentro de la red privada.

## CORS

La rúbrica penaliza los sobrepermisos, así que nada de comodines.

| Campo | Valor |
|---|---|
| `Access-Control-Allow-Origins` | El origen exacto del frontend. En desarrollo `http://localhost:4200`, en la nube la URL pública. **Nunca `*`** |
| `Access-Control-Allow-Methods` | `GET`, `POST`, `PUT`, `OPTIONS`. Sin `DELETE` ni `PATCH`, que el API no usa |
| `Access-Control-Allow-Headers` | `authorization`, `content-type` |
| `Access-Control-Expose-Headers` | *(vacío)* |
| `Access-Control-Allow-Credentials` | `false`. El token viaja en la cabecera, no en cookies |
| `Access-Control-Max-Age` | `300` |

### Verificación de CORS

| Prueba | Esperado |
|---|---|
| `OPTIONS` de preflight desde el origen del frontend | `204` con las cabeceras de la tabla |
| `OPTIONS` desde un origen no listado | Sin cabecera `Access-Control-Allow-Origin` |
| `GET` real desde el frontend | `200`, sin error de CORS en la consola del navegador |

Las tres capturas van a `infra/docs/evidencias/cors/`.

## Batería de pruebas por ruta

Indicador 8 de la EP2, 15%. Por **cada una de las 16 rutas**, tres casos:

| Caso | Esperado |
|---|---|
| Token válido con el rol correcto | `200` y el JSON esperado |
| Sin cabecera `Authorization` | `401` desde el gateway |
| Token válido con rol insuficiente | `403` desde el BFF |

Un cuarto caso vale la pena documentar aunque no lo pida la rúbrica: **token del tenant
equivocado** contra una ruta del otro grupo, por ejemplo un token de huésped contra
`/staff/report/kpis`. Debe dar `401`, porque el authorizer de esa ruta no reconoce ese issuer.
Es la prueba más clara de que la separación funciona.

Todo se documenta en una colección Postman versionada en `infra/docs/evidencias/`.

## Convención al agregar una ruta

1. Se agrega la fila a la tabla de este documento, en el mismo PR que la crea.
2. Se le asigna el authorizer que corresponda a su audiencia.
3. Se agregan sus tres casos de prueba a la colección.
4. Se actualiza el contrato OpenAPI del servicio afectado.

Una ruta sin authorizer baja el indicador 7 completo, que es el de mayor peso individual de
la EP2.
