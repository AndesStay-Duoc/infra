# Contrato — Roles y autorización

Contrato canónico de quién puede hacer qué. Cualquier cambio aquí obliga a actualizar el BFF, el
microservicio afectado y la colección de pruebas en el mismo PR.

> **Corrección del 2026-10-10.** Este documento describía **dos tenants** con los scopes
> `access_as_staff` y `access_as_guest`, roles llamados `Recepcionista` y `Huesped`, authorities en
> mayúsculas (`ROLE_ADMIN`) y endpoints `hold`/`release` colgando de `/api/catalog/units/{id}`.
> Nada de eso es lo que hay. Describía el diseño que murió con la decisión D3 del 2026-09-14,
> cuando no se pudo crear el segundo tenant. Los valores reales están abajo y se contrastaron
> contra el código.

## Identidad

Un tenant, una app registration, un scope. El detalle está en
[`../idaas/tenants.md`](../idaas/tenants.md), incluida la explicación de qué son hoy `staff` y
`guest`: prefijos de ruta, no identidades distintas.

| Dato | Valor |
|---|---|
| Scope | `AndesStay.Access` |
| Claim que lo trae | `scp` |
| Claim de roles | `roles` |

## Los cuatro roles

Los valores del claim son **exactamente** estos. No son los nombres para mostrar del portal, que sí
están en castellano.

| Valor en el claim | Nombre para mostrar | Responsabilidad |
|---|---|---|
| `Admin` | Administrador | Administra el inventario y ve los KPIs |
| `Operador` | Recepcionista | Confirma reservas, hace check-in y check-out |
| `Cliente` | Huésped | Crea y sigue sus propias reservas |
| `Auditor` | Auditor | Consulta el timeline. Solo lectura |

## Authorities

El converter antepone `ROLE_` **conservando mayúsculas y minúsculas**: `ROLE_Admin`, no
`ROLE_ADMIN`. Importa porque `hasRole('Admin')` compara literalmente.

| Claim | Authority resultante |
|---|---|
| `roles: ["Admin"]` | `ROLE_Admin` |
| `roles: ["Operador"]` | `ROLE_Operador` |
| `roles: ["Auditor"]` | `ROLE_Auditor` |
| `scp: "AndesStay.Access"` | `SCOPE_AndesStay.Access` |
| *(sin `roles`)* + `acct: 1` + el scope | `ROLE_Cliente`, **derivado** |

La derivación de `Cliente` está en `AzureRolesConverter`, presente en `ms-andesstay-bff`,
`ms-andesstay-reservations` y `ms-andesstay-catalog`. `report` y `audit` usan un converter simple:
no lo necesitan, porque el BFF no deja a un `Cliente` alcanzarlos.

## Matriz de permisos

Es la fuente de verdad. El BFF la aplica por ruta y método; cada microservicio la vuelve a aplicar
con `@PreAuthorize`, que es defensa en profundidad y no redundancia: quien alcance el puerto del
servicio sin pasar por el BFF se encuentra con la misma regla.

| Método y ruta | Admin | Operador | Cliente | Auditor |
|---|:---:|:---:|:---:|:---:|
| `GET /api/me` | ✅ | ✅ | ✅ | ✅ |
| `POST /api/reservations` | ✅ | ✅ | ✅ | ❌ |
| `GET /api/reservations` | ✅ todas | ✅ todas | ✅ **solo las suyas** | ❌ |
| `GET /api/reservations/{id}` | ✅ | ✅ | ✅ solo si es suya | ✅ |
| `PUT /api/reservations/{id}/status` | ✅ | ✅ | ⚠️ **solo cancelar la suya en CREADA** | ❌ |
| `GET /api/catalog/hostales` | ✅ | ✅ | ✅ | ❌ |
| `GET /api/catalog/hostales/{id}/units` | ✅ | ✅ | ✅ | ❌ |
| `POST /api/catalog/hostales` | ✅ | ❌ | ❌ | ❌ |
| `PUT /api/catalog/hostales/{id}` | ✅ | ❌ | ❌ | ❌ |
| `GET /api/catalog/units` | ✅ | ✅ | ✅ | ❌ |
| `GET /api/catalog/units/{id}` | ✅ | ✅ | ✅ | ❌ |
| `GET /api/catalog/units/{id}/availability` | ✅ | ✅ | ✅ | ❌ |
| `POST /api/catalog/units` | ✅ | ❌ | ❌ | ❌ |
| `PUT /api/catalog/units/{id}` | ✅ | ❌ | ❌ | ❌ |
| `DELETE /api/catalog/units/{id}` | ✅ | ❌ | ❌ | ❌ |
| `GET /api/report/**` | ✅ | ❌ | ❌ | ❌ |
| `GET /api/audit/**` | ✅ | ❌ | ❌ | ✅ |
| `/api/catalog/internal/**` | ❌ | ❌ | ❌ | ❌ |

### Las tres filas que tienen truco

**`PUT /{id}/status` para un `Cliente`.** Pasa el BFF y pasa `@PreAuthorize` si la reserva es
suya, pero `ReservationService` le limita a **una** transición: `CANCELADA`, y solo desde `CREADA`.
Cualquier otra, o una reserva ya confirmada, responde `403`. Es la transición 3 y la regla 5 del
contrato, que hasta el 2026-10-10 el sistema prometía sin cumplir. Una vez confirmada hay cupo
comprometido, así que a partir de ahí pasa por recepción.


**`GET /api/reservations` para un `Cliente`.** Devuelve `200`, no la lista completa: el servicio
filtra por el `sub` de su token. Quien decide es el rol, no un parámetro, así que un huésped no
puede pedir las de otro. Hasta el 2026-10-10 este rol quedaba fuera y la pantalla de reservas se le
abría en el frontend para terminar en `403`.

**`/api/catalog/internal/**` para todos.** El BFF lo corta con `denyAll`, incluso a un `Admin`: no
es una regla de rol, es una superficie que no se publica. Solo la llama
`ms-andesstay-reservations` dentro de la red privada, y desde el 2026-10-10 **exige JWT válido**;
antes estaba en `permitAll` y cualquiera que alcanzara el puerto 8082 podía mover los cupos sin
token. `CatalogClient` propaga el token del llamante.

## Endpoints internos, con su forma real

| Método y ruta | Qué hace |
|---|---|
| `POST /api/catalog/internal/units/{id}/hold?from=&to=&holdId=` | Compromete un cupo por cada noche de `[from, to)`. Todo o nada, idempotente por `holdId` |
| `POST /api/catalog/internal/holds/{holdId}/release` | Devuelve los cupos. Idempotente en los dos sentidos |

Sustituyen al antiguo `PATCH /internal/units/{id}/slots?delta=±1`, que no sabía de fechas, no era
idempotente y no era transaccional respecto del rango.

## Reglas de propiedad

1. Un `Cliente` solo ve y opera **sus** reservas. La comprobación la hace `ReservationSecurity`
   comparando el `sub` del token con el `guestId`.
2. Un `Cliente` solo puede cancelar, y únicamente mientras la reserva esté en `CREADA`.
3. El `guestId` y el `guestEmail` de una reserva creada por un `Cliente` se **fuerzan** desde el
   token, se mande lo que se mande en el cuerpo. Es lo que impide reservar a nombre de otro.

## Códigos de respuesta

| Situación | Código |
|---|---|
| Sin cabecera `Authorization` | `401` |
| Token expirado, con firma inválida, o con `iss` o `aud` equivocados | `401` |
| Token válido sin el rol de la ruta | `403` |
| Token válido sin `roles` ni el scope de la API | `403` |
| Rol correcto | `200`, `201` o `204` |

La diferencia entre `401` y `403` no es cosmética: `401` significa «no sé quién eres» y `403` «sé
quién eres y no te alcanza». Los cuerpos de error del dominio están en
[`estados.md`](estados.md).

## Verificación

La batería completa, 53 peticiones con aserción de código y de cuerpo, está en
[`../evidencias/autorizacion/coleccion-postman.json`](../evidencias/autorizacion/coleccion-postman.json).

```bash
newman run coleccion-postman.json -e entorno-postman.json --reporters cli,html
```

Por cada ruta se prueban tres casos: rol correcto, sin token y rol insuficiente.
