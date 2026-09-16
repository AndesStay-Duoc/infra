-- ─────────────────────────────────────────────────────────────────────────────
-- AndesStay — inicialización de MySQL
--
-- Se ejecuta UNA SOLA VEZ, cuando el volumen mysql-data está vacío. Si la base
-- ya existe, el entrypoint de la imagen ignora este directorio por completo.
--
-- La imagen ya crea la base y el usuario a partir de MYSQL_DATABASE,
-- MYSQL_USER y MYSQL_PASSWORD. Aquí solo se ajusta lo que esas variables no
-- cubren: el juego de caracteres y los permisos que Hibernate necesita.
--
-- Las tablas NO se crean aquí. Los cuatro servicios con JPA usan
-- spring.jpa.hibernate.ddl-auto=update y las generan al arrancar.
-- ─────────────────────────────────────────────────────────────────────────────

-- utf8mb4 completo: los nombres de huéspedes y las descripciones de unidades
-- llevan tildes y eñes, y utf8mb3 las corrompe.
ALTER DATABASE andesstay
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

-- Los cuatro servicios comparten esquema y cada uno crea sus propias tablas con
-- ddl-auto=update, así que el usuario de aplicación necesita DDL además de DML.
--
-- Nota: compartir un esquema entre microservicios no es lo que se recomendaría
-- en producción; aquí responde a que toda la arquitectura vive en una sola
-- instancia. Las tablas no se solapan entre servicios.
GRANT ALL PRIVILEGES ON andesstay.* TO 'andesstay'@'%';

FLUSH PRIVILEGES;
