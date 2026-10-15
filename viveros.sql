\set ON_ERROR_STOP on
CREATE DATABASE viveros ENCODING 'UTF8' TEMPLATE template0;
\connect viveros
\encoding UTF8
SET TIME ZONE 'Atlantic/Canary';

-- 1. Tablas, claves y restricciones.
BEGIN;
CREATE EXTENSION btree_gist; -- Permite impedir destinos simultaneos.

CREATE TABLE vivero (
    id_vivero INTEGER PRIMARY KEY CHECK (id_vivero > 0),
    nombre VARCHAR(100) NOT NULL CHECK (btrim(nombre) <> ''),
    latitud DOUBLE PRECISION NOT NULL CHECK (latitud BETWEEN -90 AND 90),
    longitud DOUBLE PRECISION NOT NULL CHECK (longitud BETWEEN -180 AND 180)
);

CREATE TABLE zona (
    id_zona INTEGER PRIMARY KEY CHECK (id_zona > 0),
    id_vivero INTEGER NOT NULL REFERENCES vivero ON DELETE CASCADE ON UPDATE CASCADE,
    nombre VARCHAR(100) NOT NULL CHECK (btrim(nombre) <> ''),
    latitud DOUBLE PRECISION NOT NULL CHECK (latitud BETWEEN -90 AND 90),
    longitud DOUBLE PRECISION NOT NULL CHECK (longitud BETWEEN -180 AND 180)
);

CREATE TABLE producto (
    id_producto INTEGER PRIMARY KEY CHECK (id_producto > 0),
    nombre VARCHAR(150) NOT NULL CHECK (btrim(nombre) <> ''),
    tipo VARCHAR(10) NOT NULL CHECK (tipo IN ('planta', 'jardinería', 'decoración'))
);

CREATE TABLE almacena (
    id_zona INTEGER REFERENCES zona ON DELETE CASCADE ON UPDATE CASCADE,
    id_producto INTEGER REFERENCES producto ON DELETE CASCADE ON UPDATE CASCADE,
    cantidad_disponible INTEGER NOT NULL CHECK (cantidad_disponible >= 0),
    PRIMARY KEY (id_zona, id_producto)
);

CREATE TABLE empleado (
    id_empleado INTEGER PRIMARY KEY CHECK (id_empleado > 0),
    nombre VARCHAR(150) NOT NULL CHECK (btrim(nombre) <> '')
);

CREATE TABLE destino (
    id_destino INTEGER PRIMARY KEY CHECK (id_destino > 0),
    id_empleado INTEGER NOT NULL REFERENCES empleado ON DELETE CASCADE ON UPDATE CASCADE,
    id_zona INTEGER NOT NULL REFERENCES zona ON DELETE RESTRICT ON UPDATE CASCADE,
    fecha_inicio TIMESTAMPTZ NOT NULL CHECK (isfinite(fecha_inicio)),
    fecha_fin TIMESTAMPTZ CHECK (isfinite(fecha_fin)),
    puesto VARCHAR(100) NOT NULL CHECK (btrim(puesto) <> ''),
    CHECK (fecha_fin IS NULL OR fecha_fin > fecha_inicio),
    -- Intervalos [inicio, fin): el final no se incluye; NULL deja el destino abierto.
    EXCLUDE USING gist (id_empleado WITH =,
        tstzrange(fecha_inicio, fecha_fin, '[)') WITH &&) DEFERRABLE
);

CREATE TABLE cliente (
    id_cliente INTEGER PRIMARY KEY CHECK (id_cliente > 0)
);

CREATE TABLE cliente_plus (
    id_cliente INTEGER PRIMARY KEY REFERENCES cliente ON DELETE CASCADE ON UPDATE CASCADE,
    nombre VARCHAR(150) NOT NULL CHECK (btrim(nombre) <> ''),
    email VARCHAR(254) NOT NULL
        CHECK (email ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'),
    fecha_ingreso TIMESTAMPTZ NOT NULL CHECK (isfinite(fecha_ingreso))
);

CREATE TABLE pedido (
    id_pedido INTEGER PRIMARY KEY CHECK (id_pedido > 0),
    id_empleado INTEGER NOT NULL REFERENCES empleado ON DELETE RESTRICT ON UPDATE CASCADE,
    id_cliente INTEGER REFERENCES cliente ON DELETE SET NULL ON UPDATE CASCADE, -- Puede ser anonimo.
    fecha_hora TIMESTAMPTZ NOT NULL CHECK (isfinite(fecha_hora))
);

CREATE TABLE incluye (
    id_pedido INTEGER REFERENCES pedido ON DELETE CASCADE ON UPDATE CASCADE,
    id_producto INTEGER REFERENCES producto ON DELETE RESTRICT ON UPDATE CASCADE,
    cantidad INTEGER NOT NULL CHECK (cantidad > 0),
    precio_unitario NUMERIC(10,2) NOT NULL
        CHECK (precio_unitario >= 0 AND precio_unitario <> 'NaN'::NUMERIC),
    PRIMARY KEY (id_pedido, id_producto)
);

CREATE TABLE bonificacion_mensual (
    id_bonificacion INTEGER PRIMARY KEY CHECK (id_bonificacion > 0),
    id_cliente INTEGER NOT NULL REFERENCES cliente_plus ON DELETE CASCADE ON UPDATE CASCADE,
    mes DATE NOT NULL CHECK (isfinite(mes) AND EXTRACT(DAY FROM mes) = 1),
    porcentaje NUMERIC(5,2) NOT NULL CHECK (porcentaje BETWEEN 0 AND 100),
    UNIQUE (id_cliente, mes)
);

-- 2. Calculados: las vistas suman las ventas sin guardar totales duplicados.
CREATE VIEW v_pedido AS
SELECT p.*, COALESCE(SUM(i.cantidad * i.precio_unitario), 0)::NUMERIC(20,2) AS importe_total
FROM pedido p LEFT JOIN incluye i ON p.id_pedido = i.id_pedido
GROUP BY p.id_pedido;

CREATE VIEW v_bonificacion_mensual AS
SELECT b.id_bonificacion, b.id_cliente, b.mes,
       COALESCE(SUM(p.importe_total), 0)::NUMERIC(20,2) AS volumen_mensual,
       b.porcentaje,
       ROUND(COALESCE(SUM(p.importe_total), 0) * b.porcentaje / 100, 2)::NUMERIC(20,2) AS importe
FROM bonificacion_mensual b JOIN cliente_plus c ON b.id_cliente = c.id_cliente
LEFT JOIN v_pedido p ON p.id_cliente = b.id_cliente
    AND p.fecha_hora >= c.fecha_ingreso
    AND date_trunc('month', p.fecha_hora AT TIME ZONE 'Atlantic/Canary')::DATE = b.mes
GROUP BY b.id_bonificacion;

-- 3. Reglas entre tablas: se comprueban al terminar cada transaccion.
CREATE FUNCTION comprobar_modelo() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM vivero v WHERE NOT EXISTS (
        SELECT 1 FROM zona z WHERE z.id_vivero = v.id_vivero)) THEN
        RAISE EXCEPTION 'Cada vivero debe tener una zona' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT 1 FROM pedido p WHERE NOT EXISTS (
        SELECT 1 FROM incluye i WHERE i.id_pedido = p.id_pedido)) THEN
        RAISE EXCEPTION 'Cada pedido debe tener productos' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT 1 FROM pedido p WHERE NOT EXISTS (
        SELECT 1 FROM destino d WHERE d.id_empleado = p.id_empleado
        AND tstzrange(d.fecha_inicio, d.fecha_fin, '[)') @> p.fecha_hora)) THEN
        RAISE EXCEPTION 'El responsable debe tener un destino vigente' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT 1 FROM bonificacion_mensual b JOIN cliente_plus c USING (id_cliente)
        WHERE b.mes < date_trunc('month', c.fecha_ingreso AT TIME ZONE 'Atlantic/Canary')::DATE) THEN
        RAISE EXCEPTION 'La bonificacion no puede ser anterior al alta' USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER comprobar_vivero AFTER INSERT OR UPDATE OR DELETE ON vivero
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION comprobar_modelo();
CREATE CONSTRAINT TRIGGER comprobar_zona AFTER INSERT OR UPDATE OR DELETE ON zona
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION comprobar_modelo();
CREATE CONSTRAINT TRIGGER comprobar_destino AFTER INSERT OR UPDATE OR DELETE ON destino
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION comprobar_modelo();
CREATE CONSTRAINT TRIGGER comprobar_pedido AFTER INSERT OR UPDATE OR DELETE ON pedido
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION comprobar_modelo();
CREATE CONSTRAINT TRIGGER comprobar_incluye AFTER INSERT OR UPDATE OR DELETE ON incluye
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION comprobar_modelo();
CREATE CONSTRAINT TRIGGER comprobar_cliente_plus AFTER INSERT OR UPDATE OR DELETE ON cliente_plus
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION comprobar_modelo();
CREATE CONSTRAINT TRIGGER comprobar_bonificacion AFTER INSERT OR UPDATE OR DELETE ON bonificacion_mensual
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION comprobar_modelo();

-- 4. Datos: cinco o mas filas por tabla. Porcentajes de bonificacion de ejemplo.
INSERT INTO vivero VALUES
    (1, 'Vivero La Laguna', 28.4874, -16.3159),
    (2, 'Vivero Tacoronte', 28.4768, -16.4102),
    (3, 'Vivero La Orotava', 28.3909, -16.5231),
    (4, 'Vivero Adeje', 28.1226, -16.7260),
    (5, 'Vivero Arona', 28.0996, -16.6810);

INSERT INTO zona VALUES
    (11, 1, 'Exterior', 28.4875, -16.3158),
    (12, 1, 'Almacén', 28.4876, -16.3157),
    (21, 2, 'Invernadero', 28.4769, -16.4101),
    (31, 3, 'Jardinería', 28.3910, -16.5230),
    (41, 4, 'Decoración', 28.1227, -16.7259),
    (51, 5, 'Exterior', 28.0997, -16.6809),
    (52, 5, 'Almacén auxiliar', 28.0998, -16.6808);

INSERT INTO producto VALUES
    (1, 'Geranio rojo', 'planta'),
    (2, 'Rosal', 'planta'),
    (3, 'Sustrato 20 L', 'jardinería'),
    (4, 'Tijeras de poda', 'jardinería'),
    (5, 'Maceta de barro', 'decoración'),
    (6, 'Figura de jardín', 'decoración'); -- Sin stock ni ventas todavía.

INSERT INTO almacena VALUES
    (11, 1, 40), (12, 3, 0), -- Stock cero conserva la asignación del producto.
    (21, 2, 25), (31, 4, 8), (41, 5, 12),
    (51, 1, 16), (51, 5, 6), (21, 1, 8);

INSERT INTO empleado VALUES
    (1, 'Ana Pérez Díaz'), (2, 'Bruno Hernández'),
    (3, 'Celia Martín'), (4, 'Diego González'),
    (5, 'Elena Rodríguez'), (6, 'Fabio López'); -- Sin destino ni pedidos.

INSERT INTO destino VALUES
    (1, 1, 11, '2026-01-01 09:00:00+00', '2026-10-01 09:00:00+01', 'Vendedora'),
    (2, 1, 21, '2026-10-01 09:00:00+01', NULL, 'Responsable de zona'),
    (3, 2, 12, '2026-01-01 09:00:00+00', NULL, 'Vendedor'),
    (4, 3, 31, '2026-01-01 09:00:00+00', '2026-09-20 18:00:00+01', 'Vendedora'),
    (5, 4, 41, '2026-01-01 09:00:00+00', NULL, 'Vendedor'),
    (6, 5, 51, '2026-01-01 09:00:00+00', NULL, 'Vendedora'),
    (7, 3, 31, '2026-10-01 09:00:00+01', NULL, 'Responsable de zona');
-- Destinos abiertos, cerrados, contiguos y con una pausa; nunca se solapan.

INSERT INTO cliente VALUES (1), (2), (3), (4), (5), (6), (7);
INSERT INTO cliente_plus VALUES
    (1, 'Luis García', 'luis@example.com', '2026-09-01 09:00:00+01'),
    (2, 'Carla Ramos', 'carla@example.com', '2026-09-10 12:00:00+01'),
    (3, 'David Díaz', 'david@example.com', '2026-08-01 09:00:00+01'),
    (4, 'Marta León', 'marta@example.com', '2026-10-01 09:00:00+01'),
    (5, 'Nerea Suárez', 'nerea@example.com', '2026-09-01 09:00:00+01');
-- Los clientes 6 y 7 no son Plus; 5 y 7 no tienen compras.

INSERT INTO pedido VALUES
    (101, 1, 1, '2026-09-05 10:30:00+01'),
    (102, 2, 2, '2026-09-15 11:00:00+01'),
    (103, 3, 3, '2026-09-12 12:00:00+01'),
    (104, 4, 4, '2026-10-02 13:00:00+01'),
    (105, 5, NULL, '2026-09-18 14:00:00+01'), -- Compra anónima.
    (106, 2, 6, '2026-09-19 15:00:00+01'), -- Cliente no Plus.
    (107, 1, 1, '2026-08-31 17:00:00+01'), -- Antes del alta, otro mes.
    (108, 2, 2, '2026-09-10 11:00:00+01'), -- Antes del alta, el mismo mes.
    (109, 2, 2, '2026-09-10 12:00:00+01'), -- Exactamente al darse de alta.
    (110, 1, 1, '2026-10-01 09:00:00+01'), -- Primer instante del nuevo destino.
    (111, 5, 1, '2026-09-30 23:30:00+00'), -- En Canarias ya es octubre.
    (112, 1, 1, '2026-09-01 09:00:00+01');

INSERT INTO incluye VALUES
    (101, 1, 2, 8.50), (101, 3, 1, 6.25),
    (102, 2, 1, 12.00), (102, 5, 2, 9.50),
    (103, 4, 1, 14.90), (104, 5, 3, 9.50),
    (105, 1, 1, 8.50), (106, 3, 2, 6.25),
    (107, 2, 2, 12.00), (108, 1, 1, 8.50),
    (109, 3, 1, 6.25), (110, 4, 2, 14.90),
    (110, 5, 1, 0.00), -- Artículo gratuito; el precio admite cero.
    (111, 3, 1, 6.25), (112, 1, 1, 8.50);

INSERT INTO bonificacion_mensual VALUES
    (1, 1, '2026-09-01', 5.00), (2, 2, '2026-09-01', 5.00),
    (3, 3, '2026-09-01', 2.50), (4, 4, '2026-10-01', 5.00),
    (5, 5, '2026-09-01', 0.00), -- Mes sin compras: volumen e importe cero.
    (6, 1, '2026-10-01', 10.00);
COMMIT;

-- 5. DELETE. ROLLBACK conserva los datos despues de cada ejemplo.
-- Borrado de un producto sin ventas.
BEGIN;
DELETE FROM producto WHERE id_producto = 6 RETURNING *;
ROLLBACK;

-- CASCADE: al borrar el pedido se borran sus lineas.
BEGIN;
DELETE FROM pedido WHERE id_pedido = 101;
SELECT * FROM incluye WHERE id_pedido = 101;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;

-- SET NULL conserva pedidos anonimos; CASCADE borra el alta Plus y sus bonos.
BEGIN;
DELETE FROM cliente WHERE id_cliente = 1;
SELECT id_pedido, id_cliente FROM pedido WHERE id_pedido = 101;
SELECT * FROM cliente_plus WHERE id_cliente = 1;
SELECT * FROM bonificacion_mensual WHERE id_cliente = 1;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;

-- RESTRICT impide borrar un producto vendido. Ejemplo que produciria un error:
-- DELETE FROM producto WHERE id_producto = 1;

-- 6. SELECT de las once tablas y de los atributos calculados.
\pset null '(NULL)'
\pset pager off
SELECT * FROM vivero ORDER BY id_vivero;
SELECT * FROM zona ORDER BY id_zona;
SELECT * FROM producto ORDER BY id_producto;
SELECT * FROM almacena ORDER BY id_zona, id_producto;
SELECT * FROM empleado ORDER BY id_empleado;
SELECT * FROM destino ORDER BY id_destino;
SELECT * FROM cliente ORDER BY id_cliente;
SELECT * FROM cliente_plus ORDER BY id_cliente;
SELECT * FROM pedido ORDER BY id_pedido;
SELECT * FROM incluye ORDER BY id_pedido, id_producto;
SELECT * FROM bonificacion_mensual ORDER BY id_bonificacion;
SELECT * FROM v_pedido ORDER BY id_pedido;
SELECT * FROM v_bonificacion_mensual ORDER BY id_bonificacion;
