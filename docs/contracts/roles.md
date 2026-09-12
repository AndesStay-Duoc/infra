# Contrato — Roles, claims y autorización

Contrato canónico. Define cómo se traduce un token de cualquiera de los dos tenants a
authorities de Spring, y qué rol puede llamar a qué endpoint.

## Los dos tenants

El sistema usa **dos emisores de identidad**, porque el caso pide login corporativo y la rúbrica
de la EP2 pide que los huéspedes se registren solos.

| | Tenant corporativo | Tenant de huéspedes |
|---|---|---|
| Producto | Microsoft Entra ID | Microsoft Entra External ID |
| Quiénes | Admin, Recepcionista, Auditor | Huésped |
| Alta de usuarios | El administrador los crea o invita | **Auto-registro desde el frontend** |
| App registration | `AndesStay-Staff` | `AndesStay-Guest` |
| Scope | `access_as_staff` | `access_as_guest` |
| Audience | `api://<staff-client-id>` | `api://<guest-client-id>` |
| Rutas del gateway | `/staff/*` | `/guest/*` |

Ambos usan **Authorization Code con PKCE**, con `state` y `nonce`.

## Mapeo de claims a authorities

El claim de roles es `roles`, un arreglo de strings. Cada valor se transforma anteponiendo
`ROLE_` y pasando a mayúsculas.

| Valor en el claim `roles` | Authority en Spring | Tenant |
|---|---|---|
| `Admin` | `ROLE_ADMIN` | corporativo |
| `Recepcionista` | `ROLE_RECEPCIONISTA` | corporativo |
| `Auditor` | `ROLE_AUDITOR` | corporativo |
| `Huesped` | `ROLE_HUESPED` | huéspedes |

El converter es común a todos los servicios y se copia como parte del paquete `common`. Un token
sin claim `roles`, o con un valor no listado, queda **sin authorities**: autentica pero no
autoriza nada, y toda llamada responde `403`.

## Claims que se esperan en el token

| Claim | Uso |
|---|---|
| `iss` | Selecciona el decoder. Debe coincidir exactamente con uno de los dos issuers |
| `aud` | **Se valida explícitamente.** Spring no lo hace por defecto |
| `exp`, `nbf` | Vigencia |
| `sub` | Identificador estable del usuario. Es el `guestId` de las reservas |
| `roles` | Autorización |
| `scp` o `scope` | Debe contener `access_as_staff` o `access_as_guest` según el tenant |
| `name`, `email` | Presentación en el frontend y registro en auditoría |

## Matriz endpoint × rol

| Endpoint | Admin | Recepcionista | Huésped | Auditor |
|---|---|---|---|---|
| `POST /api/reservations` | ✔ | ✔ | ✔ | — |
| `GET /api/reservations` | ✔ todas | ✔ todas | ✔ solo propias | — |
| `GET /api/reservations/{id}` | ✔ | ✔ | ✔ solo propias | — |
| `PUT /api/reservations/{id}/status` | ✔ | ✔ | ✔ solo cancelar propias en `CREADA` | — |
| `GET /api/catalog/units` | ✔ | ✔ | ✔ | — |
| `POST /api/catalog/units` | ✔ | — | — | — |
| `PUT /api/catalog/units/{id}` | ✔ | — | — | — |
| `POST /api/catalog/units/{id}/hold` | interno | interno | — | — |
| `POST /api/catalog/units/{id}/release` | interno | interno | — | — |
| `GET /api/report/kpis` | ✔ | — | — | — |
| `GET /api/report/top-units` | ✔ | — | — | — |
| `GET /api/audit` | ✔ | — | — | ✔ |
| `GET /api/audit/{reservationId}` | ✔ | — | — | ✔ |

"interno" significa que solo lo llama `ms-andesstay-reservations`, propagando el JWT del usuario
que originó la operación, para no perder la trazabilidad en la auditoría.

## Autorización por propiedad del recurso

Las celdas que dicen "solo propias" no se resuelven con `@PreAuthorize` a secas: hay que
comparar el `sub` del token contra el `guestId` de la reserva. Si no coincide, la respuesta es
`403`, nunca `404` — no se filtra la existencia del recurso a alguien autenticado.

## Códigos de respuesta

Esta tabla es la que se evalúa en la EP1, indicador 2, y en la EP2, indicador 7.

| Situación | Código |
|---|---|
| Sin cabecera `Authorization` | `401` |
| Token con issuer desconocido | `401` |
| Firma inválida | `401` |
| Token expirado | `401` |
| **Audience incorrecta** | `401` |
| Scope faltante | `403` |
| Token válido, rol sin permiso | `403` |
| Token válido, rol correcto, recurso ajeno | `403` |
| Token válido y autorizado | `200` |

El cuerpo de error es siempre JSON y no revela detalles internos:

```json
{ "error": "TOKEN_INVALIDO", "timestamp": "2026-09-09T14:30:00Z", "traceId": "..." }
```

## Dónde se valida qué

| Capa | Valida |
|---|---|
| API Gateway | `iss`, `aud`, firma y vigencia, por ruta y con el authorizer correspondiente |
| BFF | Lo mismo, más el rol y la pertenencia del recurso |
| Servicio de dominio | Lo mismo que el BFF. **No se confía en que el BFF ya validó** |

La validación se repite en cada capa a propósito: un servicio de dominio nunca debe quedar
expuesto si alguien alcanza su puerto directamente.
