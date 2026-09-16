# Contrato — Rutas del API Gateway

Contrato canónico del **API Manager**. Es la base de los indicadores 1 (rutas, 13%), 2 (CORS, 7%)
y 7 (validación JWT en todas las rutas, 20%) de la EP2.

## Tipo de API

**HTTP API** de AWS API Gateway, no REST API. El JWT Authorizer nativo, que es lo que evalúa el
indicador 7, pertenece a HTTP API.

## Por qué las rutas se parten en `/staff` y `/guest`

La separación nació cuando el diseño contemplaba **dos app registrations** con
audiences distintas. La decisión D3 del 2026-09-14 la dejó en **una sola**
(`704a544f-3d92-44f5-aef9-8559574cff34`), porque no se pudo crear un segundo
tenant, así que hoy **no hay dos audiences que distinguir**.

El split se conserva igualmente, por dos razones:

1. Deja legible en la consola del gateway qué superficie consume cada tipo de
   usuario, que es lo que evalúa el indicador 1.
2. Ya está implementado en el BFF, que decide por **rol** (`Admin`, `Operador`,
   `Cliente`, `Auditor`) y no por audience. Ver `SecurityConfig.java` de
   `ms-andesstay-bff`.

La diferenciación real, entonces, la hace el BFF: un `Cliente` que llame a
`/staff/report/kpis` obtiene `403`, no `401`.

## Authorizer

Un único JWT Authorizer para las 16 rutas:

| Nombre | Issuer | Audience | Scope requerido |
|---|---|---|---|
| `entra-andesstay` | `https://login.microsoftonline.com/055d11d1-8ae0-4221-a6f7-b50be0a623b4/v2.0` | `704a544f-…` **y** `api://704a544f-…` | `AndesStay.Access` |

El issuer es el de **v2.0** porque el manifiesto fija `requestedAccessTokenVersion: 2`. Por ese
mismo motivo el authorizer declara **las dos formas de audiencia**: los tokens v2.0 traen `aud`
como el GUID pelado, y `api://<client-id>` corresponde a los v1.0. Con una sola declarada, el
authorizer rechaza todo con `the token does not have a valid audience`.
Los identificadores completos están en `infra/docs/idaas/tenants.md`; no son
secretos, pero los secretos de la aplicación nunca se versionan.

## Tabla de rutas

Todas las rutas integran contra el mismo backend: `ms-andesstay-bff` en `ec2-apps`.

| # | Método | Ruta en el gateway | Authorizer | Destino en el BFF | Roles |
|---|---|---|---|---|---|
| 1 | `POST` | `/guest/reservations` | `entra-andesstay` | `POST /api/reservations` | Huésped |
| 2 | `GET` | `/guest/reservations` | `entra-andesstay` | `GET /api/reservations` | Huésped |
| 3 | `GET` | `/guest/reservations/{id}` | `entra-andesstay` | `GET /api/reservations/{id}` | Huésped |
| 4 | `PUT` | `/guest/reservations/{id}/status` | `entra-andesstay` | `PUT /api/reservations/{id}/status` | Huésped, solo cancelar |
| 5 | `GET` | `/guest/catalog/units` | `entra-andesstay` | `GET /api/catalog/units` | ⚠ ver nota |
| 6 | `POST` | `/staff/reservations` | `entra-andesstay` | `POST /api/reservations` | Recepcionista |
| 7 | `GET` | `/staff/reservations` | `entra-andesstay` | `GET /api/reservations` | Admin, Recepcionista |
| 8 | `GET` | `/staff/reservations/{id}` | `entra-andesstay` | `GET /api/reservations/{id}` | Admin, Recepcionista |
| 9 | `PUT` | `/staff/reservations/{id}/status` | `entra-andesstay` | `PUT /api/reservations/{id}/status` | Admin, Recepcionista |
| 10 | `GET` | `/staff/catalog/units` | `entra-andesstay` | `GET /api/catalog/units` | Admin, Recepcionista |
| 11 | `POST` | `/staff/catalog/units` | `entra-andesstay` | `POST /api/catalog/units` | Admin |
| 12 | `PUT` | `/staff/catalog/units/{id}` | `entra-andesstay` | `PUT /api/catalog/units/{id}` | Admin |
| 13 | `GET` | `/staff/report/kpis` | `entra-andesstay` | `GET /api/report/kpis` | Admin |
| 14 | `GET` | `/staff/report/top-units` | `entra-andesstay` | `GET /api/report/top-units` | Admin |
| 15 | `GET` | `/staff/audit/events` | `entra-andesstay` | `GET /api/audit/events` | Admin, Auditor |
| 16 | `GET` | `/staff/audit/reservations/{id}/timeline` | `entra-andesstay` | `GET /api/audit/reservations/{id}/timeline` | Admin, Auditor |

### Ruta de consumo de la SPA

A las 16 anteriores se suma una decimoséptima:

| Método | Ruta | Authorizer | Destino |
|---|---|---|---|
| `GET` | `/api/{proxy+}` | `entra-andesstay` | `/api/**` del BFF, sin traducción |
| `POST` | `/api/{proxy+}` | `entra-andesstay` | idem |
| `PUT` | `/api/{proxy+}` | `entra-andesstay` | idem |
| `DELETE` | `/api/{proxy+}` | `entra-andesstay` | idem |

**Los cuatro métodos van por separado; `ANY` no sirve.** `ANY` también captura el `OPTIONS` del
preflight, y entonces el authorizer lo evalúa: como el navegador no envía `Authorization` en un
preflight, responde `401` y la petición real nunca llega a salir. Declarando los métodos uno a uno,
el `OPTIONS` no coincide con ninguna ruta y lo atiende el manejador de CORS de API Gateway, que
devuelve `204`. Es el mismo motivo por el que las 16 rutas explícitas no dan problema.

Existe porque **el frontend llama a `/api/*`, no a `/staff/*` ni `/guest/*`**: sus servicios
(`catalog.service.ts`, `report.service.ts`, `reservation.service.ts`, `audit.service.ts` y el
`GET /api/me` de `auth.service.ts`) construyen las URL sobre `apiUri` + `/api/...`. Además
`/api/me` no tiene equivalente en la tabla de 16, y es el endpoint del que la SPA obtiene
`effectiveRoles`.

Las dos superficies conviven a propósito:

- `/staff/*` y `/guest/*` son el **contrato público** del API Manager: rutas enumeradas, cada una
  con su authorizer y su integración, que es lo que evalúa el indicador 1.
- `/api/{proxy+}` es la que **consume la SPA**. Lleva el mismo authorizer, así que no abre ninguna
  brecha: sin un JWT válido de Entra ID devuelve `401` igual que las demás.

Al ser rutas comodín, comparten una única integración cuya URI sí puede usar `{proxy}`; las 16
explícitas no pueden, porque API Gateway exige que toda variable de path de la integración exista
en la route key.

**Las 20 rutas llevan authorizer. Ninguna queda abierta.** No existe ruta `$default` sin
proteger: una petición a un path no declarado devuelve `404` del gateway.

> **Nota sobre la ruta 5.** La ruta existe en el gateway y pasa el authorizer, pero **un `Cliente`
> recibe `403`**: `SecurityConfig` del BFF restringe `GET /api/catalog/**` a `Admin` y `Operador`.
> Hoy solo la pueden usar esos dos roles, igual que la ruta 10.
>
> Se documenta así, en lugar de abrirla, porque habilitar el flujo de huésped exige dos cambios
> sobre código ya verificado en producción: permitir el rol en el BFF y copiar `AzureRolesConverter`
> a `ms-andesstay-catalog`, que usa un converter simple y no derivaría `ROLE_Cliente`. Queda como
> mejora pendiente, no como defecto silencioso.
>
> Un `Cliente` alcanza únicamente `/api/reservations/**`: crear una reserva y consultar las suyas.

Los endpoints internos `hold` y `release` de catalog **no se publican en el gateway**: solo los
llama `ms-andesstay-reservations` dentro de la red privada.

### Integración

Cada ruta lleva **su propia integración** de tipo HTTP_PROXY, cuya URI replica el mismo path:

```
GET  /staff/report/kpis          ->  http://<elastic-ip>/staff/report/kpis
GET  /staff/reservations/{id}    ->  http://<elastic-ip>/staff/reservations/{id}
```

Una integración única con `{proxy}` compartida por las 16 rutas **no es válida**: API Gateway
exige que toda variable de path de la URI aparezca también en la route key, y rechaza la
creación con `The following path variables in the integration URI are not present in the route
key: proxy`. Solo sería posible con una ruta comodín `ANY /{proxy+}`, que dejaría de cumplir el
requisito de 16 rutas declaradas.

La traducción de `/staff/*` y `/guest/*` al `/api/*` que entiende el BFF **no se hace con
parameter mapping**, sino en nginx (`infra/deploy/nginx/conf.d/andesstay.conf.template`,
bloque `location ~ ^/(staff|guest)/(.*)$`). Así queda versionada en git y revisable en un PR,
en lugar de existir solo en la consola de AWS y perderse cuando el laboratorio se reinicia.

La integración añade además la cabecera `X-Gateway-Secret` por parameter mapping. Nginx
devuelve `403` a toda petición a `/api/**`, `/staff/**` o `/guest/**` que no la traiga: es lo
que impide alcanzar el BFF saltándose el gateway, ya que el puerto 80 tiene que estar abierto
a internet (las integraciones de API Gateway salen desde IPs de AWS que no se pueden acotar en
un Security Group).

### Hosting de la SPA

El frontend **no se sirve desde este API**. Vive en un HTTP API aparte, `andesstay-web`, con una
única ruta `$default` hacia el mismo nginx. De ese modo `andesstay-api` conserva la propiedad de
que las 16 rutas llevan authorizer y ninguna queda abierta.

Servir la SPA a través de API Gateway no es un rodeo: aporta el certificado TLS válido de AWS
sobre `https://<web-api-id>.execute-api.us-east-1.amazonaws.com`, que es lo que hace posible
registrar el origen como Redirect URI en Entra ID. Entra no acepta redirect URIs con IP cruda, y
API Gateway no integra contra backends con certificado autofirmado.

## CORS

La rúbrica penaliza los sobrepermisos, así que nada de comodines.

| Campo | Valor |
|---|---|
| `Access-Control-Allow-Origins` | El origen exacto del frontend. En desarrollo `http://localhost:4200`, en la nube la URL pública. **Nunca `*`** |
| `Access-Control-Allow-Methods` | `GET`, `POST`, `PUT`, `DELETE`, `OPTIONS`. Sin `PATCH`. `DELETE` es necesario: `catalog.service.ts` borra unidades con `DELETE /api/catalog/units/{id}` |
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

Dos casos más conviene documentar aunque no los pida la rúbrica:

- **Token con audience equivocada** — un JWT emitido para otra aplicación contra cualquier ruta.
  Debe dar `401` desde el gateway, porque el authorizer valida `aud`. Con una sola app
  registration ya no existe el caso de "token del otro tenant" que describía la versión anterior
  de este documento.
- **Petición sin `X-Gateway-Secret`** — un `curl` directo a `http://<ip>/api/me` saltándose el
  gateway. Debe dar `403` desde nginx, sin llegar al BFF.

Todo se documenta en una colección Postman versionada en `infra/docs/evidencias/`.

## Convención al agregar una ruta

1. Se agrega la fila a la tabla de este documento, en el mismo PR que la crea.
2. Se le asigna el authorizer `entra-andesstay`, igual que las demás.
3. Se agregan sus tres casos de prueba a la colección.
4. Se actualiza el contrato OpenAPI del servicio afectado.

Una ruta sin authorizer baja el indicador 7 completo, que es el de mayor peso individual de
la EP2.
