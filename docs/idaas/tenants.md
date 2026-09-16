# Identificadores de identidad

Datos del tenant y del App Registration que AndesStay usa realmente. Ninguno es
secreto: el `clientId` y el `tenantId` viajan en el bundle del frontend y en la
URL de inicio de sesión. Los secretos de la aplicación nunca se versionan.

> **Corrección del 2026-09-16.** Este archivo describía el tenant
> `cfe8706e-e5ae-44dd-8092-b4941bda8bd9` con la aplicación
> `da4e2482-c0e7-41d8-a298-b45a59c8d6bc` y el scope `access_as_staff`, que no son
> los que usa el sistema. Es el hallazgo H-01 del plan de auditoría, resuelto a
> favor de la identidad del código. Los valores anteriores quedan descartados.

## Tenant y aplicación

Una sola app registration, por la decisión D3 del 2026-09-14: no se pudo crear un
segundo tenant, así que la separación entre personal y huéspedes dejó de hacerse
por audiencia y pasa a resolverse por rol.

| Dato | Valor |
|---|---|
| Tenant ID | `055d11d1-8ae0-4221-a6f7-b50be0a623b4` |
| Client ID | `704a544f-3d92-44f5-aef9-8559574cff34` |
| Application ID URI | `api://704a544f-3d92-44f5-aef9-8559574cff34` |
| Scope | `api://704a544f-3d92-44f5-aef9-8559574cff34/AndesStay.Access` |
| Authority | `https://login.microsoftonline.com/055d11d1-8ae0-4221-a6f7-b50be0a623b4` |
| Issuer (`iss` del token) | `https://login.microsoftonline.com/055d11d1-8ae0-4221-a6f7-b50be0a623b4/v2.0` |
| JWKS | `https://login.microsoftonline.com/055d11d1-8ae0-4221-a6f7-b50be0a623b4/discovery/v2.0/keys` |
| App Roles | `Admin`, `Operador`, `Cliente`, `Auditor` |
| Plataforma del registro | Single-page application |
| Versión del access token | `2` (`requestedAccessTokenVersion` en el manifiesto) |

## Audiencia: las dos formas

Los tokens v2.0 traen `aud` como el **GUID pelado**; `api://<client-id>` es la
forma de los v1.0. Tanto el BFF como el JWT Authorizer del API Gateway declaran
**ambas**. Con una sola, el authorizer rechaza todo con

```
www-authenticate: Bearer error="invalid_token"
                  error_description="the token does not have a valid audience"
```

## Claims necesarios en el access token

| Claim | Para qué | Obligatorio |
|---|---|---|
| `roles` | App Roles asignados; el BFF autoriza con ellos | Solo si el usuario tiene rol asignado |
| `scp` | Debe contener `AndesStay.Access` | Sí |
| `acct` | `0` miembro, `1` invitado | **Sí**, ver abajo |
| `email` | Identificar al huésped en las reservas | Recomendado |

`acct` es un **optional claim** y hay que declararlo explícitamente para el
access token, en *Token configuration* del portal. Sin él, `AzureRolesConverter`
del BFF nunca deriva `ROLE_Cliente` y un huésped recién autoregistrado inicia
sesión pero recibe `403` en todo.

Es el único discriminante entre personal e invitado que queda desde la decisión
D3: en el diseño original de dos aplicaciones esa distinción la daba la
audiencia del token.

## Roles

| Rol | Se obtiene | Alcance |
|---|---|---|
| `Admin` | Asignación explícita | Todo |
| `Operador` | Asignación explícita | Reservas y lectura de catálogo |
| `Auditor` | Asignación explícita | Auditoría, solo lectura |
| `Cliente` | **Derivado por el BFF**: sin claim `roles`, `acct == 1` y `scp` con `AndesStay.Access` | Sus propias reservas |

`Cliente` no se asigna en el portal. Su App Role existe en el manifiesto
(`e8967400-6532-4337-a284-759e19d859dc`), pero Entra ID no asigna App Roles de
forma automática al autoregistrarse, y asignarlos requeriría automatización con
Microsoft Graph. La derivación en el BFF es la decisión D2.

**La derivación solo está en `ms-andesstay-bff` y `ms-andesstay-reservations`.**
`catalog`, `report` y `audit` usan un converter simple que no la aplica. Hoy no
rompe nada porque el BFF solo permite a un `Cliente` alcanzar
`/api/reservations/**`.

## Auto-registro de huéspedes

Por **Email one-time passcode**, con `Assignment required = No`. Un usuario
autoregistrado entra al tenant como invitado (`acct: 1`, `idp: mail`) y sin claim
`roles`.

## Redirect URIs

Plataforma Single-page application, **sin barra final** y respetando mayúsculas.
Deben coincidir carácter por carácter con `PUBLIC_WEB_ORIGIN` del `.env`
compartido y con el `redirectUri` de `assets/config.json`.

| Entorno | URI |
|---|---|
| Desarrollo | `http://localhost:4200` |
| Desarrollo | `http://localhost:4200/login` |
| Nube | `https://<web-api-id>.execute-api.us-east-1.amazonaws.com` |
| Nube | `https://<web-api-id>.execute-api.us-east-1.amazonaws.com/login` |

El identificador vigente del API está en `docs/DESPLIEGUE-ACTIVO.md`, fuera del
repositorio. Entra ID **no acepta redirect URIs con IP cruda**: por eso el
frontend se sirve a través de API Gateway, que aporta un dominio con certificado
válido, y no directamente desde la instancia.

En una plataforma SPA no hace falta configurar *Allowed origins* aparte: Entra
habilita CORS para los redirect URIs registrados.

## Verificación

```bash
# El issuer del documento de descubrimiento debe terminar en /v2.0
curl -s https://login.microsoftonline.com/055d11d1-8ae0-4221-a6f7-b50be0a623b4/v2.0/.well-known/openid-configuration \
  | python -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
```

Sobre un access token ya emitido, se comprueba que `aud`, `iss`, `scp`, `ver` y
`acct` sean los esperados. Un scope inventado sobre el mismo Application ID URI
devuelve `AADSTS65005`, lo que confirma que el scope real está expuesto.
