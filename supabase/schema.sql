-- =====================================================================
-- RutaVerde AQP - Esquema de base de datos para Supabase
-- (PostgreSQL 16 + PostGIS). Producto Académico N.° 2 - Taller de Proyectos 1
-- Cumple la tercera forma normal (3FN). Ver sección 2 del informe.
--
-- CÓMO USARLO: Supabase > SQL Editor > New query > pegar todo > Run.
-- Se puede ejecutar varias veces: primero BORRA las tablas del proyecto
-- (y sus datos) y luego las vuelve a crear.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- 0. Limpieza (permite volver a ejecutar el script sin errores)
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_saldo_puntos, v_tablero_zona, v_kilos_reciclador, v_entregas CASCADE;
DROP TABLE IF EXISTS movimiento_puntos, entrega, parada, ruta, incidencia, programacion,
    solicitud_material, solicitud, asignacion, reciclador, usuario, material,
    asociacion, zona, rol CASCADE;
DROP FUNCTION IF EXISTS mi_id_usuario();

-- ---------------------------------------------------------------------
-- 1. Catálogos
-- ---------------------------------------------------------------------
CREATE TABLE rol (
    id_rol      SMALLSERIAL PRIMARY KEY,
    nombre      VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE zona (
    id_zona     SERIAL PRIMARY KEY,
    nombre      VARCHAR(80) NOT NULL UNIQUE,
    area        GEOMETRY(POLYGON, 4326) NOT NULL
);

CREATE TABLE asociacion (
    id_asociacion SERIAL PRIMARY KEY,
    ruc           CHAR(11)     NOT NULL UNIQUE CHECK (ruc ~ '^(10|20)[0-9]{9}$'),
    razon_social  VARCHAR(120) NOT NULL,
    telefono      VARCHAR(9)   CHECK (telefono ~ '^[0-9]{6,9}$')
);

CREATE TABLE material (
    id_material   SMALLSERIAL PRIMARY KEY,
    nombre        VARCHAR(40)  NOT NULL UNIQUE,
    puntos_por_kg SMALLINT     NOT NULL CHECK (puntos_por_kg BETWEEN 0 AND 100),
    precio_ref_kg NUMERIC(6,2) NOT NULL CHECK (precio_ref_kg >= 0)
);

-- ---------------------------------------------------------------------
-- 2. Usuarios (el correo y la contraseña los guarda Supabase Auth)
-- ---------------------------------------------------------------------
CREATE TABLE usuario (
    id_usuario        SERIAL PRIMARY KEY,
    id_auth           UUID         NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
    id_rol            SMALLINT     NOT NULL REFERENCES rol(id_rol),
    id_zona           INTEGER      REFERENCES zona(id_zona),
    nombres           VARCHAR(60)  NOT NULL,
    apellidos         VARCHAR(60)  NOT NULL,
    celular           CHAR(9)      NOT NULL UNIQUE CHECK (celular ~ '^9[0-9]{8}$'),
    direccion         VARCHAR(150) NOT NULL,
    ubicacion         GEOGRAPHY(POINT, 4326),
    consentimiento_en TIMESTAMPTZ  NOT NULL,              -- Ley 29733
    activo            BOOLEAN      NOT NULL DEFAULT TRUE, -- baja lógica
    creado_en         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Subtipo 1:1 de usuario: solo recicladores formalizados (Ley 29419)
CREATE TABLE reciclador (
    id_usuario         INTEGER PRIMARY KEY REFERENCES usuario(id_usuario),
    id_asociacion      INTEGER     NOT NULL REFERENCES asociacion(id_asociacion),
    nro_acreditacion   VARCHAR(20) NOT NULL UNIQUE,
    fecha_acreditacion DATE        NOT NULL
);

CREATE TABLE asignacion (
    id_asignacion  SERIAL PRIMARY KEY,
    id_reciclador  INTEGER NOT NULL REFERENCES reciclador(id_usuario),
    id_zona        INTEGER NOT NULL REFERENCES zona(id_zona),
    asignado_por   INTEGER NOT NULL REFERENCES usuario(id_usuario),
    fecha_inicio   DATE    NOT NULL,
    fecha_fin      DATE    NOT NULL,
    CHECK (fecha_fin >= fecha_inicio)
);

-- ---------------------------------------------------------------------
-- 3. Solicitudes
-- ---------------------------------------------------------------------
CREATE TABLE solicitud (
    id_solicitud     SERIAL PRIMARY KEY,
    id_usuario       INTEGER     NOT NULL REFERENCES usuario(id_usuario),
    fecha_programada DATE        NOT NULL,
    franja           VARCHAR(6)  NOT NULL CHECK (franja IN ('manana', 'tarde')),
    volumen          VARCHAR(12) NOT NULL CHECK (volumen IN ('bolsa', 'saco', 'varios_sacos')),
    estado           VARCHAR(10) NOT NULL DEFAULT 'pendiente'
                     CHECK (estado IN ('pendiente', 'asignada', 'en_ruta', 'atendida', 'cancelada')),
    codigo_qr        UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    creado_en        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE solicitud_material (
    id_solicitud INTEGER  NOT NULL REFERENCES solicitud(id_solicitud) ON DELETE CASCADE,
    id_material  SMALLINT NOT NULL REFERENCES material(id_material),
    PRIMARY KEY (id_solicitud, id_material)
);

CREATE TABLE programacion (               -- HU-04 (fase posterior)
    id_programacion SERIAL PRIMARY KEY,
    id_usuario      INTEGER    NOT NULL REFERENCES usuario(id_usuario),
    dia_semana      SMALLINT   NOT NULL CHECK (dia_semana BETWEEN 1 AND 7),
    franja          VARCHAR(6) NOT NULL CHECK (franja IN ('manana', 'tarde')),
    activa          BOOLEAN    NOT NULL DEFAULT TRUE,
    UNIQUE (id_usuario, dia_semana, franja)
);

CREATE TABLE incidencia (                 -- HU-12 (fase posterior)
    id_incidencia SERIAL PRIMARY KEY,
    id_solicitud  INTEGER      NOT NULL REFERENCES solicitud(id_solicitud),
    descripcion   VARCHAR(300) NOT NULL CHECK (char_length(descripcion) >= 10),
    estado        VARCHAR(10)  NOT NULL DEFAULT 'abierta'
                  CHECK (estado IN ('abierta', 'atendida', 'cerrada')),
    creado_en     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 4. Rutas y pesaje
-- ---------------------------------------------------------------------
CREATE TABLE ruta (
    id_ruta       SERIAL PRIMARY KEY,
    id_reciclador INTEGER      NOT NULL REFERENCES reciclador(id_usuario),
    fecha         DATE         NOT NULL,
    distancia_km  NUMERIC(6,2) CHECK (distancia_km >= 0),
    estado        VARCHAR(10)  NOT NULL DEFAULT 'generada'
                  CHECK (estado IN ('generada', 'en_curso', 'cerrada')),
    UNIQUE (id_reciclador, fecha)
);

CREATE TABLE parada (
    id_parada     SERIAL PRIMARY KEY,
    id_ruta       INTEGER     NOT NULL REFERENCES ruta(id_ruta) ON DELETE CASCADE,
    id_solicitud  INTEGER     NOT NULL UNIQUE REFERENCES solicitud(id_solicitud),
    orden         SMALLINT    NOT NULL CHECK (orden >= 1),
    hora_estimada TIME,
    estado        VARCHAR(12) NOT NULL DEFAULT 'pendiente'
                  CHECK (estado IN ('pendiente', 'atendida', 'no_atendida')),
    motivo        VARCHAR(40),
    UNIQUE (id_ruta, orden),
    CHECK (estado <> 'no_atendida' OR motivo IS NOT NULL)
);

CREATE TABLE entrega (
    id_entrega      SERIAL PRIMARY KEY,
    id_parada       INTEGER      NOT NULL REFERENCES parada(id_parada),
    id_material     SMALLINT     NOT NULL REFERENCES material(id_material),
    peso_kg         NUMERIC(4,1) NOT NULL CHECK (peso_kg > 0 AND peso_kg <= 999.9),
    uuid_local      UUID         NOT NULL UNIQUE,  -- evita duplicados al sincronizar
    registrado_en   TIMESTAMPTZ  NOT NULL,         -- hora en el celular
    sincronizado_en TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (id_parada, id_material)
);

-- Historial de puntos: guarda el valor otorgado en ese momento,
-- aunque luego cambie material.puntos_por_kg.
CREATE TABLE movimiento_puntos (
    id_movimiento SERIAL PRIMARY KEY,
    id_usuario    INTEGER     NOT NULL REFERENCES usuario(id_usuario),
    id_entrega    INTEGER     UNIQUE REFERENCES entrega(id_entrega),
    puntos        INTEGER     NOT NULL CHECK (puntos <> 0),
    tipo          VARCHAR(12) NOT NULL CHECK (tipo IN ('acumulacion', 'canje', 'ajuste')),
    fecha         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((tipo = 'acumulacion') = (id_entrega IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 5. Índices
-- ---------------------------------------------------------------------
CREATE INDEX ix_solicitud_fecha_estado ON solicitud (fecha_programada, estado);
CREATE INDEX ix_asignacion_reciclador  ON asignacion (id_reciclador, fecha_inicio, fecha_fin);
CREATE INDEX ix_entrega_registrado     ON entrega (registrado_en);
CREATE INDEX ix_zona_area              ON zona USING GIST (area);

-- ---------------------------------------------------------------------
-- 6. Vistas para reportes (HU-07, HU-08, HU-10, HU-11): se calculan, no se guardan
--    security_invoker = on: la vista respeta la seguridad (RLS) de quien consulta
-- ---------------------------------------------------------------------
CREATE VIEW v_entregas WITH (security_invoker = on) AS
SELECT e.id_entrega, e.registrado_en::date AS fecha, e.peso_kg,
       m.nombre AS material, m.precio_ref_kg,
       r.id_reciclador, s.id_usuario AS id_vecino, u.id_zona
FROM entrega e
JOIN material  m ON m.id_material  = e.id_material
JOIN parada    p ON p.id_parada    = e.id_parada
JOIN ruta      r ON r.id_ruta      = p.id_ruta
JOIN solicitud s ON s.id_solicitud = p.id_solicitud
JOIN usuario   u ON u.id_usuario   = s.id_usuario;

CREATE VIEW v_kilos_reciclador WITH (security_invoker = on) AS        -- HU-07
SELECT id_reciclador, fecha, SUM(peso_kg) AS kilos,
       SUM(peso_kg * precio_ref_kg) AS ingreso_estimado
FROM v_entregas GROUP BY id_reciclador, fecha;

CREATE VIEW v_tablero_zona WITH (security_invoker = on) AS            -- HU-10 y HU-11
SELECT z.nombre AS zona, v.material, v.fecha,
       SUM(v.peso_kg) AS kilos, COUNT(*) AS entregas
FROM v_entregas v JOIN zona z ON z.id_zona = v.id_zona
GROUP BY z.nombre, v.material, v.fecha;

CREATE VIEW v_saldo_puntos WITH (security_invoker = on) AS            -- HU-08
SELECT id_usuario, SUM(puntos) AS saldo
FROM movimiento_puntos GROUP BY id_usuario;

-- ---------------------------------------------------------------------
-- 7. Seguridad a nivel de fila (RLS)
--    Todas las tablas quedan cerradas por defecto. Solo se abre lo que
--    necesita el Sprint 1; las políticas de los demás roles se agregan
--    en el sprint de cada historia.
-- ---------------------------------------------------------------------
ALTER TABLE rol                ENABLE ROW LEVEL SECURITY;
ALTER TABLE zona               ENABLE ROW LEVEL SECURITY;
ALTER TABLE asociacion         ENABLE ROW LEVEL SECURITY;
ALTER TABLE material           ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario            ENABLE ROW LEVEL SECURITY;
ALTER TABLE reciclador         ENABLE ROW LEVEL SECURITY;
ALTER TABLE asignacion         ENABLE ROW LEVEL SECURITY;
ALTER TABLE solicitud          ENABLE ROW LEVEL SECURITY;
ALTER TABLE solicitud_material ENABLE ROW LEVEL SECURITY;
ALTER TABLE programacion       ENABLE ROW LEVEL SECURITY;
ALTER TABLE incidencia         ENABLE ROW LEVEL SECURITY;
ALTER TABLE ruta               ENABLE ROW LEVEL SECURITY;
ALTER TABLE parada             ENABLE ROW LEVEL SECURITY;
ALTER TABLE entrega            ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimiento_puntos  ENABLE ROW LEVEL SECURITY;

-- id_usuario de la persona que inició sesión
CREATE FUNCTION mi_id_usuario() RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT id_usuario FROM usuario WHERE id_auth = auth.uid()
$$;

-- Catálogos: cualquier usuario con sesión puede leerlos
CREATE POLICY rol_lectura      ON rol      FOR SELECT TO authenticated USING (true);
CREATE POLICY zona_lectura     ON zona     FOR SELECT TO authenticated USING (true);
CREATE POLICY material_lectura ON material FOR SELECT TO authenticated USING (true);

-- HU-01: cada persona ve y edita solo su perfil; al registrarse solo
-- puede elegir el rol vecino o comercio
CREATE POLICY usuario_ver_propio ON usuario FOR SELECT TO authenticated
    USING (id_auth = auth.uid());
CREATE POLICY usuario_registro ON usuario FOR INSERT TO authenticated
    WITH CHECK (id_auth = auth.uid()
                AND id_rol IN (SELECT id_rol FROM rol WHERE nombre IN ('vecino', 'comercio')));
CREATE POLICY usuario_editar_propio ON usuario FOR UPDATE TO authenticated
    USING (id_auth = auth.uid()) WITH CHECK (id_auth = auth.uid());

-- HU-02 y HU-03: cada vecino ve, crea y cancela solo sus solicitudes
CREATE POLICY solicitud_ver_propia ON solicitud FOR SELECT TO authenticated
    USING (id_usuario = mi_id_usuario());
CREATE POLICY solicitud_crear ON solicitud FOR INSERT TO authenticated
    WITH CHECK (id_usuario = mi_id_usuario() AND estado = 'pendiente');
CREATE POLICY solicitud_cancelar ON solicitud FOR UPDATE TO authenticated
    USING (id_usuario = mi_id_usuario() AND estado IN ('pendiente', 'asignada'))
    WITH CHECK (id_usuario = mi_id_usuario() AND estado IN ('pendiente', 'asignada', 'cancelada'));

CREATE POLICY solicitud_material_propia ON solicitud_material FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM solicitud s
                   WHERE s.id_solicitud = solicitud_material.id_solicitud
                     AND s.id_usuario = mi_id_usuario()))
    WITH CHECK (EXISTS (SELECT 1 FROM solicitud s
                        WHERE s.id_solicitud = solicitud_material.id_solicitud
                          AND s.id_usuario = mi_id_usuario()
                          AND s.estado = 'pendiente'));

-- ---------------------------------------------------------------------
-- 8. Datos iniciales
-- ---------------------------------------------------------------------
INSERT INTO rol (nombre) VALUES
  ('vecino'), ('comercio'), ('reciclador'), ('admin_asociacion'), ('gestor_municipal');

INSERT INTO material (nombre, puntos_por_kg, precio_ref_kg) VALUES
  ('Cartón', 10, 0.40), ('Plástico PET', 10, 1.20), ('Papel', 8, 0.50), ('Vidrio', 5, 0.15);
