-- =====================================================================
--  NOS FUIMOS — Esquema de base de datos (Supabase / PostgreSQL)
--  Versión 1.0 — MVP
--
--  Cómo usarlo: en Supabase → SQL Editor → New query → pegar TODO este
--  archivo → Run. Se puede ejecutar varias veces sin romper nada
--  (usa IF NOT EXISTS / OR REPLACE / ON CONFLICT).
--
--  Contenido:
--   1. Extensiones y tipos (enums)
--   2. Tablas
--   3. Funciones auxiliares y triggers
--   4. Funciones de negocio (RPC): cotizar, crear_reserva, cancelar,
--      asignar conductor, cambiar estado, calificar
--   5. Seguridad: RLS por rol (cliente / conductor / admin)
--   6. Vistas para el panel admin
--   7. Datos de prueba (ciudades, rutas, tarifas, vehículos, cupones)
-- =====================================================================


-- =====================================================================
-- 1. EXTENSIONES Y TIPOS
-- =====================================================================
create extension if not exists "pgcrypto";

do $$ begin
  create type rol_usuario as enum ('cliente', 'conductor', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type estado_reserva as enum (
    'pendiente_pago',     -- creada, esperando pago
    'confirmada',         -- pago verificado, sin conductor todavía
    'asignada',           -- conductor y vehículo asignados
    'en_camino',          -- conductor va hacia el punto de recogida
    'en_curso',           -- viaje iniciado
    'completada',
    'cancelada_cliente',
    'cancelada_admin',
    'no_show'             -- el cliente no se presentó
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type estado_pago as enum ('pendiente', 'verificando', 'aprobado', 'rechazado', 'reembolsado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type metodo_pago as enum ('pago_movil', 'transferencia', 'zelle', 'efectivo', 'tarjeta', 'otro');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_descuento as enum ('porcentaje', 'monto_fijo');
exception when duplicate_object then null; end $$;

do $$ begin
  create type estado_ticket as enum ('abierto', 'en_proceso', 'resuelto', 'cerrado');
exception when duplicate_object then null; end $$;


-- =====================================================================
-- 2. TABLAS
-- =====================================================================

-- ---------- Perfiles (uno por usuario de auth.users) ----------
create table if not exists perfiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  rol           rol_usuario not null default 'cliente',
  nombre        text,
  apellido      text,
  telefono      text,
  email         text,
  cedula        text,
  foto_url      text,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index if not exists perfiles_rol_idx on perfiles(rol);
create index if not exists perfiles_telefono_idx on perfiles(telefono);

-- ---------- Ciudades ----------
create table if not exists ciudades (
  id        serial primary key,
  nombre    text not null unique,
  estado    text not null,             -- estado/región de Venezuela
  activa    boolean not null default true,
  orden     int not null default 100   -- para ordenar en la app
);

-- ---------- Tipos de vehículo ----------
create table if not exists tipos_vehiculo (
  id              serial primary key,
  codigo          text not null unique,      -- 'sedan', 'suv', 'van'
  nombre          text not null,             -- 'Sedán'
  descripcion     text,
  capacidad_pasajeros int not null check (capacidad_pasajeros > 0),
  capacidad_equipaje  int not null default 2 check (capacidad_equipaje >= 0), -- maletas grandes
  icono           text,                      -- emoji o nombre de ícono
  activo          boolean not null default true,
  orden           int not null default 100
);

-- ---------- Rutas (origen -> destino) ----------
create table if not exists rutas (
  id            serial primary key,
  origen_id     int not null references ciudades(id),
  destino_id    int not null references ciudades(id),
  distancia_km  numeric(7,1),
  duracion_min  int,
  activa        boolean not null default true,
  unique (origen_id, destino_id),
  check (origen_id <> destino_id)
);

-- ---------- Tarifas: precio TOTAL del vehículo por ruta y tipo ----------
create table if not exists tarifas (
  id                serial primary key,
  ruta_id           int not null references rutas(id) on delete cascade,
  tipo_vehiculo_id  int not null references tipos_vehiculo(id),
  precio_total      numeric(10,2) not null check (precio_total >= 0),
  moneda            text not null default 'USD',
  activa            boolean not null default true,
  vigente_desde     date not null default current_date,
  vigente_hasta     date,
  unique (ruta_id, tipo_vehiculo_id, vigente_desde)
);

-- ---------- Conductores ----------
-- perfil_id es opcional: al inicio el admin registra conductores sin cuenta
-- y los asigna a mano. Cuando el conductor cree su cuenta, se enlaza.
create table if not exists conductores (
  id              uuid primary key default gen_random_uuid(),
  perfil_id       uuid unique references perfiles(id) on delete set null,
  nombre          text not null,
  telefono        text not null,
  cedula          text,
  licencia        text,
  foto_url        text,
  calificacion    numeric(3,2) not null default 5.00,
  total_viajes    int not null default 0,
  activo          boolean not null default true,
  notas           text,
  creado_en       timestamptz not null default now(),
  actualizado_en  timestamptz not null default now()
);

-- ---------- Vehículos ----------
create table if not exists vehiculos (
  id                uuid primary key default gen_random_uuid(),
  tipo_vehiculo_id  int not null references tipos_vehiculo(id),
  conductor_id      uuid references conductores(id) on delete set null,
  marca             text not null,
  modelo            text not null,
  anio              int,
  color             text,
  placa             text not null unique,
  capacidad_pasajeros int not null,
  foto_url          text,
  activo            boolean not null default true,
  creado_en         timestamptz not null default now(),
  actualizado_en    timestamptz not null default now()
);

-- ---------- Cupones ----------
create table if not exists cupones (
  id              serial primary key,
  codigo          text not null unique,
  descripcion     text,
  tipo            tipo_descuento not null,
  valor           numeric(10,2) not null check (valor > 0), -- % o USD
  monto_minimo    numeric(10,2) not null default 0,
  max_usos        int,                 -- null = ilimitado
  max_usos_por_usuario int not null default 1,
  usos            int not null default 0,
  vigente_desde   timestamptz not null default now(),
  vigente_hasta   timestamptz,
  activo          boolean not null default true,
  creado_en       timestamptz not null default now()
);

-- ---------- Política de cancelación (configurable) ----------
-- Cada fila: "si cancela con al menos X horas de anticipación, reembolso Y %".
-- Se aplica la fila con horas_minimas más alta que cumpla.
create table if not exists politicas_cancelacion (
  id                    serial primary key,
  nombre                text not null,
  horas_minimas         int not null check (horas_minimas >= 0),
  porcentaje_reembolso  int not null check (porcentaje_reembolso between 0 and 100),
  activa                boolean not null default true
);

-- ---------- Reservas (el vehículo COMPLETO) ----------
create table if not exists reservas (
  id                uuid primary key default gen_random_uuid(),
  codigo            text not null unique,                 -- NF-XXXXXX (lo genera un trigger)
  cliente_id        uuid not null references perfiles(id),
  ruta_id           int not null references rutas(id),
  tipo_vehiculo_id  int not null references tipos_vehiculo(id),
  fecha_viaje       date not null,
  hora_viaje        time not null,
  pasajeros         int not null check (pasajeros > 0),
  equipaje          int not null default 0 check (equipaje >= 0),
  direccion_recogida text,
  direccion_destino  text,
  notas             text,
  -- precios
  precio_base       numeric(10,2) not null,
  descuento         numeric(10,2) not null default 0,
  precio_total      numeric(10,2) not null,
  moneda            text not null default 'USD',
  cupon_id          int references cupones(id),
  -- estado y asignación
  estado            estado_reserva not null default 'pendiente_pago',
  conductor_id      uuid references conductores(id),
  vehiculo_id       uuid references vehiculos(id),
  asignada_en       timestamptz,
  -- cancelación
  cancelada_en      timestamptz,
  motivo_cancelacion text,
  monto_reembolso   numeric(10,2),
  -- auditoría
  creada_en         timestamptz not null default now(),
  actualizada_en    timestamptz not null default now()
);
create index if not exists reservas_cliente_idx   on reservas(cliente_id);
create index if not exists reservas_conductor_idx on reservas(conductor_id);
create index if not exists reservas_estado_idx    on reservas(estado);
create index if not exists reservas_fecha_idx     on reservas(fecha_viaje);

-- ---------- Pasajeros de cada reserva ----------
create table if not exists pasajeros (
  id          uuid primary key default gen_random_uuid(),
  reserva_id  uuid not null references reservas(id) on delete cascade,
  nombre      text not null,
  cedula      text,
  telefono    text,
  es_titular  boolean not null default false
);
create index if not exists pasajeros_reserva_idx on pasajeros(reserva_id);

-- ---------- Historial de estados ----------
create table if not exists historial_estados (
  id            bigserial primary key,
  reserva_id    uuid not null references reservas(id) on delete cascade,
  estado_anterior estado_reserva,
  estado_nuevo  estado_reserva not null,
  cambiado_por  uuid references perfiles(id),
  comentario    text,
  creado_en     timestamptz not null default now()
);
create index if not exists historial_reserva_idx on historial_estados(reserva_id);

-- ---------- Pagos (modular: no atado a un proveedor) ----------
create table if not exists pagos (
  id            uuid primary key default gen_random_uuid(),
  reserva_id    uuid not null references reservas(id) on delete cascade,
  metodo        metodo_pago not null,
  proveedor     text,                   -- 'manual', 'stripe', 'mercadopago', etc.
  referencia    text,                   -- nro de referencia / id externo
  monto         numeric(10,2) not null check (monto > 0),
  moneda        text not null default 'USD',
  estado        estado_pago not null default 'pendiente',
  comprobante_url text,
  datos_extra   jsonb not null default '{}'::jsonb, -- respuesta del proveedor, etc.
  verificado_por uuid references perfiles(id),
  verificado_en timestamptz,
  creado_en     timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index if not exists pagos_reserva_idx on pagos(reserva_id);
create index if not exists pagos_estado_idx  on pagos(estado);

-- ---------- Uso de cupones ----------
create table if not exists usos_cupon (
  id          bigserial primary key,
  cupon_id    int not null references cupones(id),
  cliente_id  uuid not null references perfiles(id),
  reserva_id  uuid not null references reservas(id) on delete cascade,
  descuento   numeric(10,2) not null,
  creado_en   timestamptz not null default now()
);

-- ---------- Calificaciones ----------
create table if not exists calificaciones (
  id            uuid primary key default gen_random_uuid(),
  reserva_id    uuid not null unique references reservas(id) on delete cascade,
  cliente_id    uuid not null references perfiles(id),
  conductor_id  uuid references conductores(id),
  puntuacion    int not null check (puntuacion between 1 and 5),
  comentario    text,
  creado_en     timestamptz not null default now()
);

-- ---------- Soporte ----------
create table if not exists tickets_soporte (
  id          uuid primary key default gen_random_uuid(),
  cliente_id  uuid not null references perfiles(id),
  reserva_id  uuid references reservas(id) on delete set null,
  asunto      text not null,
  mensaje     text not null,
  estado      estado_ticket not null default 'abierto',
  respuesta   text,
  respondido_por uuid references perfiles(id),
  creado_en   timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

-- ---------- Configuración general (clave / valor) ----------
create table if not exists configuracion (
  clave       text primary key,
  valor       jsonb not null,
  descripcion text,
  actualizado_en timestamptz not null default now()
);

-- ---------- Ubicaciones GPS (preparado para tiempo real, fase 2) ----------
create table if not exists ubicaciones_conductor (
  id            bigserial primary key,
  conductor_id  uuid not null references conductores(id) on delete cascade,
  reserva_id    uuid references reservas(id) on delete set null,
  lat           double precision not null,
  lng           double precision not null,
  velocidad     numeric(6,2),
  registrado_en timestamptz not null default now()
);
create index if not exists ubicaciones_conductor_idx on ubicaciones_conductor(conductor_id, registrado_en desc);


-- =====================================================================
-- 3. FUNCIONES AUXILIARES Y TRIGGERS
-- =====================================================================

-- ---- actualizado_en automático ----
create or replace function set_actualizado_en() returns trigger
language plpgsql as $$
begin
  if to_jsonb(new) ? 'actualizado_en' then new.actualizado_en := now(); end if;
  if to_jsonb(new) ? 'actualizada_en' then new.actualizada_en := now(); end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['perfiles','conductores','vehiculos','reservas','pagos','tickets_soporte']
  loop
    execute format('drop trigger if exists trg_%s_actualizado on %I', t, t);
    execute format('create trigger trg_%s_actualizado before update on %I
                    for each row execute function set_actualizado_en()', t, t);
  end loop;
end $$;

-- ---- crear perfil al registrarse un usuario (auth.users) ----
create or replace function manejar_nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (id, email, telefono, nombre, apellido)
  values (
    new.id,
    new.email,
    new.phone,
    coalesce(new.raw_user_meta_data->>'nombre', ''),
    coalesce(new.raw_user_meta_data->>'apellido', '')
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function manejar_nuevo_usuario();

-- ---- código de reserva NF-XXXXXX ----
create or replace function generar_codigo_reserva() returns text
language plpgsql as $$
declare
  alfabeto text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- sin 0/O/1/I para evitar confusión
  v_codigo text;
  i int;
begin
  loop
    v_codigo := 'NF-';
    for i in 1..6 loop
      v_codigo := v_codigo || substr(alfabeto, 1 + floor(random() * length(alfabeto))::int, 1);
    end loop;
    exit when not exists (select 1 from reservas r where r.codigo = v_codigo);
  end loop;
  return v_codigo;
end $$;

create or replace function asignar_codigo_reserva() returns trigger
language plpgsql as $$
begin
  if new.codigo is null or new.codigo = '' then
    new.codigo := generar_codigo_reserva();
  end if;
  return new;
end $$;

drop trigger if exists trg_reservas_codigo on reservas;
create trigger trg_reservas_codigo before insert on reservas
  for each row execute function asignar_codigo_reserva();

-- ---- historial automático de estados ----
create or replace function registrar_cambio_estado() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into historial_estados (reserva_id, estado_anterior, estado_nuevo, cambiado_por)
    values (new.id, null, new.estado, auth.uid());
  elsif new.estado is distinct from old.estado then
    insert into historial_estados (reserva_id, estado_anterior, estado_nuevo, cambiado_por)
    values (new.id, old.estado, new.estado, auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists trg_reservas_historial on reservas;
create trigger trg_reservas_historial after insert or update on reservas
  for each row execute function registrar_cambio_estado();

-- ---- helpers de rol (security definer para evitar recursión en RLS) ----
create or replace function rol_actual() returns rol_usuario
language sql stable security definer set search_path = public as $$
  select rol from perfiles where id = auth.uid();
$$;

create or replace function es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol = 'admin' from perfiles where id = auth.uid()), false);
$$;

create or replace function conductor_actual_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from conductores where perfil_id = auth.uid();
$$;

-- ---- actualizar promedio de calificación del conductor ----
create or replace function actualizar_calificacion_conductor() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.conductor_id is not null then
    update conductores c
       set calificacion = (select round(avg(puntuacion)::numeric, 2) from calificaciones where conductor_id = new.conductor_id)
     where c.id = new.conductor_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_calificacion_conductor on calificaciones;
create trigger trg_calificacion_conductor after insert or update on calificaciones
  for each row execute function actualizar_calificacion_conductor();


-- =====================================================================
-- 4. FUNCIONES DE NEGOCIO (RPC) — la app las llama con supabase.rpc()
-- =====================================================================

-- ---- 4.1 COTIZAR: devuelve los tipos de vehículo disponibles con precio total ----
-- Uso: supabase.rpc('cotizar', { p_origen_id, p_destino_id, p_pasajeros, p_equipaje })
create or replace function cotizar(
  p_origen_id int,
  p_destino_id int,
  p_pasajeros int default 1,
  p_equipaje int default 0
) returns table (
  ruta_id int,
  tipo_vehiculo_id int,
  codigo text,
  nombre text,
  descripcion text,
  icono text,
  capacidad_pasajeros int,
  capacidad_equipaje int,
  precio_total numeric,
  moneda text,
  distancia_km numeric,
  duracion_min int,
  disponible boolean,
  motivo text
)
language sql stable security definer set search_path = public as $$
  select
    r.id, tv.id, tv.codigo, tv.nombre, tv.descripcion, tv.icono,
    tv.capacidad_pasajeros, tv.capacidad_equipaje,
    t.precio_total, t.moneda, r.distancia_km, r.duracion_min,
    (tv.capacidad_pasajeros >= p_pasajeros and tv.capacidad_equipaje >= p_equipaje) as disponible,
    case
      when tv.capacidad_pasajeros < p_pasajeros then 'Capacidad insuficiente de pasajeros'
      when tv.capacidad_equipaje  < p_equipaje  then 'Capacidad insuficiente de equipaje'
      else null
    end as motivo
  from rutas r
  join tarifas t on t.ruta_id = r.id and t.activa
       and t.vigente_desde <= current_date
       and (t.vigente_hasta is null or t.vigente_hasta >= current_date)
  join tipos_vehiculo tv on tv.id = t.tipo_vehiculo_id and tv.activo
  where r.origen_id = p_origen_id and r.destino_id = p_destino_id and r.activa
  order by tv.orden, t.precio_total;
$$;

-- ---- 4.2 VALIDAR CUPÓN: devuelve el descuento aplicable sobre un monto ----
create or replace function validar_cupon(p_codigo text, p_monto numeric)
returns table (valido boolean, cupon_id int, descuento numeric, mensaje text)
language plpgsql stable security definer set search_path = public as $$
declare c cupones%rowtype; usos_usuario int; d numeric;
begin
  select * into c from cupones where upper(codigo) = upper(trim(p_codigo));
  if not found then return query select false, null::int, 0::numeric, 'Cupón no existe'; return; end if;
  if not c.activo then return query select false, c.id, 0::numeric, 'Cupón inactivo'; return; end if;
  if c.vigente_hasta is not null and c.vigente_hasta < now() then
    return query select false, c.id, 0::numeric, 'Cupón vencido'; return; end if;
  if c.vigente_desde > now() then
    return query select false, c.id, 0::numeric, 'Cupón aún no vigente'; return; end if;
  if c.max_usos is not null and c.usos >= c.max_usos then
    return query select false, c.id, 0::numeric, 'Cupón agotado'; return; end if;
  if p_monto < c.monto_minimo then
    return query select false, c.id, 0::numeric, 'Monto mínimo: ' || c.monto_minimo || ' USD'; return; end if;
  select count(*) into usos_usuario from usos_cupon u where u.cupon_id = c.id and u.cliente_id = auth.uid();
  if usos_usuario >= c.max_usos_por_usuario then
    return query select false, c.id, 0::numeric, 'Ya usaste este cupón'; return; end if;

  if c.tipo = 'porcentaje' then d := round(p_monto * c.valor / 100, 2);
  else d := least(c.valor, p_monto); end if;
  return query select true, c.id, d, 'Descuento aplicado';
end $$;

-- ---- 4.3 CREAR RESERVA: calcula el precio en el servidor (nunca confía en el front) ----
-- Uso: supabase.rpc('crear_reserva', { p_origen_id, p_destino_id, p_tipo_vehiculo_id,
--        p_fecha, p_hora, p_pasajeros, p_equipaje, p_direccion_recogida, p_direccion_destino,
--        p_notas, p_cupon, p_pasajeros_json })
-- p_pasajeros_json: [{"nombre":"Ana Pérez","cedula":"V12345678","telefono":"0414...","es_titular":true}, ...]
create or replace function crear_reserva(
  p_origen_id int,
  p_destino_id int,
  p_tipo_vehiculo_id int,
  p_fecha date,
  p_hora time,
  p_pasajeros int,
  p_equipaje int default 0,
  p_direccion_recogida text default null,
  p_direccion_destino text default null,
  p_notas text default null,
  p_cupon text default null,
  p_pasajeros_json jsonb default '[]'::jsonb
) returns reservas
language plpgsql security definer set search_path = public as $$
declare
  v_ruta rutas%rowtype;
  v_tipo tipos_vehiculo%rowtype;
  v_precio numeric;
  v_desc numeric := 0;
  v_cupon_id int;
  v_valido boolean;
  v_msg text;
  v_reserva reservas%rowtype;
  p jsonb;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if p_fecha < current_date then raise exception 'La fecha del viaje no puede ser en el pasado'; end if;
  if (p_fecha + p_hora) < now() + interval '2 hours' then
    raise exception 'Las reservas deben hacerse con al menos 2 horas de anticipación';
  end if;

  select * into v_ruta from rutas where origen_id = p_origen_id and destino_id = p_destino_id and activa;
  if not found then raise exception 'Ruta no disponible'; end if;

  select * into v_tipo from tipos_vehiculo where id = p_tipo_vehiculo_id and activo;
  if not found then raise exception 'Tipo de vehículo no disponible'; end if;
  if p_pasajeros > v_tipo.capacidad_pasajeros then raise exception 'El vehículo admite máximo % pasajeros', v_tipo.capacidad_pasajeros; end if;
  if p_equipaje > v_tipo.capacidad_equipaje then raise exception 'El vehículo admite máximo % maletas', v_tipo.capacidad_equipaje; end if;

  select precio_total into v_precio from tarifas
   where ruta_id = v_ruta.id and tipo_vehiculo_id = p_tipo_vehiculo_id and activa
     and vigente_desde <= current_date and (vigente_hasta is null or vigente_hasta >= current_date)
   order by vigente_desde desc limit 1;
  if v_precio is null then raise exception 'No hay tarifa para esta ruta y vehículo'; end if;

  if p_cupon is not null and trim(p_cupon) <> '' then
    select valido, cupon_id, descuento, mensaje into v_valido, v_cupon_id, v_desc, v_msg
      from validar_cupon(p_cupon, v_precio);
    if not v_valido then raise exception 'Cupón inválido: %', v_msg; end if;
  end if;

  insert into reservas (cliente_id, ruta_id, tipo_vehiculo_id, fecha_viaje, hora_viaje,
                        pasajeros, equipaje, direccion_recogida, direccion_destino, notas,
                        precio_base, descuento, precio_total, cupon_id, estado)
  values (auth.uid(), v_ruta.id, p_tipo_vehiculo_id, p_fecha, p_hora,
          p_pasajeros, p_equipaje, p_direccion_recogida, p_direccion_destino, p_notas,
          v_precio, v_desc, v_precio - v_desc, v_cupon_id, 'pendiente_pago')
  returning * into v_reserva;

  -- pasajeros
  for p in select * from jsonb_array_elements(coalesce(p_pasajeros_json, '[]'::jsonb)) loop
    insert into pasajeros (reserva_id, nombre, cedula, telefono, es_titular)
    values (v_reserva.id, p->>'nombre', p->>'cedula', p->>'telefono', coalesce((p->>'es_titular')::boolean, false));
  end loop;

  -- registrar uso de cupón
  if v_cupon_id is not null then
    insert into usos_cupon (cupon_id, cliente_id, reserva_id, descuento) values (v_cupon_id, auth.uid(), v_reserva.id, v_desc);
    update cupones set usos = usos + 1 where id = v_cupon_id;
  end if;

  return v_reserva;
end $$;

-- ---- 4.4 REGISTRAR PAGO (el cliente reporta su pago; el admin lo aprueba) ----
create or replace function registrar_pago(
  p_reserva_id uuid,
  p_metodo metodo_pago,
  p_referencia text,
  p_monto numeric,
  p_comprobante_url text default null,
  p_proveedor text default 'manual'
) returns pagos
language plpgsql security definer set search_path = public as $$
declare v_res reservas%rowtype; v_pago pagos%rowtype;
begin
  select * into v_res from reservas where id = p_reserva_id;
  if not found then raise exception 'Reserva no encontrada'; end if;
  if v_res.cliente_id <> auth.uid() and not es_admin() then raise exception 'Sin permiso'; end if;
  if v_res.estado <> 'pendiente_pago' then raise exception 'La reserva no está pendiente de pago'; end if;

  insert into pagos (reserva_id, metodo, proveedor, referencia, monto, comprobante_url, estado)
  values (p_reserva_id, p_metodo, p_proveedor, p_referencia, p_monto, p_comprobante_url, 'verificando')
  returning * into v_pago;
  return v_pago;
end $$;

-- ---- 4.5 APROBAR / RECHAZAR PAGO (solo admin) ----
create or replace function revisar_pago(p_pago_id uuid, p_aprobar boolean, p_comentario text default null)
returns pagos
language plpgsql security definer set search_path = public as $$
declare v_pago pagos%rowtype;
begin
  if not es_admin() then raise exception 'Solo administradores'; end if;
  update pagos set estado = (case when p_aprobar then 'aprobado' else 'rechazado' end)::estado_pago,
                   verificado_por = auth.uid(), verificado_en = now(),
                   datos_extra = datos_extra || jsonb_build_object('comentario', p_comentario)
   where id = p_pago_id returning * into v_pago;
  if not found then raise exception 'Pago no encontrado'; end if;
  if p_aprobar then
    update reservas set estado = 'confirmada' where id = v_pago.reserva_id and estado = 'pendiente_pago';
  end if;
  return v_pago;
end $$;

-- ---- 4.6 CALCULAR REEMBOLSO según política configurable ----
create or replace function calcular_reembolso(p_reserva_id uuid)
returns table (porcentaje int, monto numeric, politica text)
language sql stable security definer set search_path = public as $$
  with r as (select * from reservas where id = p_reserva_id),
  horas as (select extract(epoch from ((r.fecha_viaje + r.hora_viaje) - now()))/3600 as h, r.precio_total from r),
  pol as (
    select p.* from politicas_cancelacion p, horas
     where p.activa and horas.h >= p.horas_minimas
     order by p.horas_minimas desc limit 1
  )
  select coalesce(pol.porcentaje_reembolso, 0),
         round(horas.precio_total * coalesce(pol.porcentaje_reembolso, 0) / 100.0, 2),
         coalesce(pol.nombre, 'Sin reembolso')
  from horas left join pol on true;
$$;

-- ---- 4.7 CANCELAR RESERVA (cliente o admin) ----
create or replace function cancelar_reserva(p_reserva_id uuid, p_motivo text default null)
returns reservas
language plpgsql security definer set search_path = public as $$
declare v_res reservas%rowtype; v_pct int; v_monto numeric; v_pol text;
begin
  select * into v_res from reservas where id = p_reserva_id;
  if not found then raise exception 'Reserva no encontrada'; end if;
  if v_res.cliente_id <> auth.uid() and not es_admin() then raise exception 'Sin permiso'; end if;
  if v_res.estado in ('completada','cancelada_cliente','cancelada_admin','no_show','en_curso') then
    raise exception 'Esta reserva ya no se puede cancelar (estado: %)', v_res.estado;
  end if;

  select porcentaje, monto, politica into v_pct, v_monto, v_pol from calcular_reembolso(p_reserva_id);
  -- si nunca pagó, no hay reembolso
  if v_res.estado = 'pendiente_pago' then v_monto := 0; end if;

  update reservas
     set estado = (case when es_admin() then 'cancelada_admin' else 'cancelada_cliente' end)::estado_reserva,
         cancelada_en = now(), motivo_cancelacion = p_motivo, monto_reembolso = v_monto
   where id = p_reserva_id returning * into v_res;

  if v_monto > 0 then
    update pagos set estado = 'reembolsado' where reserva_id = p_reserva_id and estado = 'aprobado';
  end if;
  return v_res;
end $$;

-- ---- 4.8 ASIGNAR CONDUCTOR Y VEHÍCULO (admin; manual al inicio) ----
create or replace function asignar_conductor(p_reserva_id uuid, p_conductor_id uuid, p_vehiculo_id uuid)
returns reservas
language plpgsql security definer set search_path = public as $$
declare v_res reservas%rowtype; v_veh vehiculos%rowtype;
begin
  if not es_admin() then raise exception 'Solo administradores'; end if;
  select * into v_res from reservas where id = p_reserva_id;
  if not found then raise exception 'Reserva no encontrada'; end if;
  if v_res.estado not in ('confirmada','asignada') then raise exception 'La reserva debe estar confirmada para asignar'; end if;
  select * into v_veh from vehiculos where id = p_vehiculo_id and activo;
  if not found then raise exception 'Vehículo no disponible'; end if;
  if v_veh.tipo_vehiculo_id <> v_res.tipo_vehiculo_id then raise exception 'El vehículo no es del tipo reservado'; end if;
  if v_veh.capacidad_pasajeros < v_res.pasajeros then raise exception 'El vehículo no tiene capacidad suficiente'; end if;
  -- evitar doble asignación el mismo día/hora (ventana de 1 h)
  if exists (
    select 1 from reservas x
     where x.id <> p_reserva_id and x.conductor_id = p_conductor_id
       and x.estado in ('asignada','en_camino','en_curso')
       and x.fecha_viaje = v_res.fecha_viaje
       and abs(extract(epoch from (x.hora_viaje - v_res.hora_viaje))) < 3600
  ) then raise exception 'El conductor ya tiene un viaje a esa hora'; end if;

  update reservas set conductor_id = p_conductor_id, vehiculo_id = p_vehiculo_id,
                      estado = 'asignada', asignada_en = now()
   where id = p_reserva_id returning * into v_res;
  return v_res;
end $$;

-- ---- 4.9 CAMBIAR ESTADO DEL VIAJE (conductor asignado o admin) ----
create or replace function cambiar_estado_viaje(p_reserva_id uuid, p_estado estado_reserva, p_comentario text default null)
returns reservas
language plpgsql security definer set search_path = public as $$
declare v_res reservas%rowtype; v_ok boolean;
begin
  select * into v_res from reservas where id = p_reserva_id;
  if not found then raise exception 'Reserva no encontrada'; end if;
  if not es_admin() and (v_res.conductor_id is null or v_res.conductor_id <> conductor_actual_id()) then
    raise exception 'Sin permiso';
  end if;
  -- transiciones válidas
  v_ok := case
    when v_res.estado = 'asignada'  and p_estado in ('en_camino','no_show','cancelada_admin') then true
    when v_res.estado = 'en_camino' and p_estado in ('en_curso','no_show','cancelada_admin') then true
    when v_res.estado = 'en_curso'  and p_estado in ('completada') then true
    when es_admin() then true   -- el admin puede forzar cualquier estado
    else false end;
  if not v_ok then raise exception 'Transición no permitida: % → %', v_res.estado, p_estado; end if;

  update reservas set estado = p_estado where id = p_reserva_id returning * into v_res;
  if p_comentario is not null then
    update historial_estados set comentario = p_comentario
     where id = (select max(id) from historial_estados where reserva_id = p_reserva_id);
  end if;
  if p_estado = 'completada' and v_res.conductor_id is not null then
    update conductores set total_viajes = total_viajes + 1 where id = v_res.conductor_id;
  end if;
  return v_res;
end $$;

-- ---- 4.10 CALIFICAR VIAJE (cliente, solo reservas completadas) ----
create or replace function calificar_viaje(p_reserva_id uuid, p_puntuacion int, p_comentario text default null)
returns calificaciones
language plpgsql security definer set search_path = public as $$
declare v_res reservas%rowtype; v_cal calificaciones%rowtype;
begin
  select * into v_res from reservas where id = p_reserva_id and cliente_id = auth.uid();
  if not found then raise exception 'Reserva no encontrada'; end if;
  if v_res.estado <> 'completada' then raise exception 'Solo puedes calificar viajes completados'; end if;
  insert into calificaciones (reserva_id, cliente_id, conductor_id, puntuacion, comentario)
  values (p_reserva_id, auth.uid(), v_res.conductor_id, p_puntuacion, p_comentario)
  on conflict (reserva_id) do update set puntuacion = excluded.puntuacion, comentario = excluded.comentario
  returning * into v_cal;
  return v_cal;
end $$;

-- ---- 4.11 MI RESERVA COMPLETA (detalle con ruta, vehículo y conductor) ----
create or replace function detalle_reserva(p_reserva_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'reserva', to_jsonb(r),
    'origen', co.nombre, 'destino', cd.nombre,
    'tipo_vehiculo', to_jsonb(tv),
    'pasajeros', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from pasajeros p where p.reserva_id = r.id),
    'pagos', (select coalesce(jsonb_agg(to_jsonb(pg) order by pg.creado_en), '[]'::jsonb) from pagos pg where pg.reserva_id = r.id),
    'conductor', case when r.estado in ('asignada','en_camino','en_curso','completada') and c.id is not null
                      then jsonb_build_object('nombre', c.nombre, 'telefono', c.telefono, 'foto_url', c.foto_url,
                                              'calificacion', c.calificacion, 'total_viajes', c.total_viajes)
                      else null end,
    'vehiculo', case when v.id is not null
                     then jsonb_build_object('marca', v.marca, 'modelo', v.modelo, 'color', v.color, 'placa', v.placa, 'foto_url', v.foto_url)
                     else null end,
    'historial', (select coalesce(jsonb_agg(jsonb_build_object('estado', h.estado_nuevo, 'fecha', h.creado_en) order by h.creado_en), '[]'::jsonb)
                  from historial_estados h where h.reserva_id = r.id),
    'calificacion', (select to_jsonb(ca) from calificaciones ca where ca.reserva_id = r.id),
    'reembolso_si_cancela', (select to_jsonb(x) from calcular_reembolso(r.id) x)
  )
  from reservas r
  join rutas ru on ru.id = r.ruta_id
  join ciudades co on co.id = ru.origen_id
  join ciudades cd on cd.id = ru.destino_id
  join tipos_vehiculo tv on tv.id = r.tipo_vehiculo_id
  left join conductores c on c.id = r.conductor_id
  left join vehiculos v on v.id = r.vehiculo_id
  where r.id = p_reserva_id
    and (r.cliente_id = auth.uid() or es_admin() or r.conductor_id = conductor_actual_id());
$$;


-- =====================================================================
-- 5. SEGURIDAD — RLS
-- =====================================================================
alter table perfiles              enable row level security;
alter table ciudades              enable row level security;
alter table tipos_vehiculo        enable row level security;
alter table rutas                 enable row level security;
alter table tarifas               enable row level security;
alter table conductores           enable row level security;
alter table vehiculos             enable row level security;
alter table cupones               enable row level security;
alter table politicas_cancelacion enable row level security;
alter table reservas              enable row level security;
alter table pasajeros             enable row level security;
alter table historial_estados     enable row level security;
alter table pagos                 enable row level security;
alter table usos_cupon            enable row level security;
alter table calificaciones        enable row level security;
alter table tickets_soporte       enable row level security;
alter table configuracion         enable row level security;
alter table ubicaciones_conductor enable row level security;

-- Limpiar políticas previas (para poder re-ejecutar el script)
do $$
declare p record;
begin
  for p in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy if exists %I on %I', p.policyname, p.tablename);
  end loop;
end $$;

-- ---- Catálogos: lectura pública (anon y autenticados), escritura solo admin ----
create policy "catalogo_lectura" on ciudades       for select using (true);
create policy "catalogo_lectura" on tipos_vehiculo for select using (true);
create policy "catalogo_lectura" on rutas          for select using (true);
create policy "catalogo_lectura" on tarifas        for select using (true);
create policy "catalogo_lectura" on politicas_cancelacion for select using (true);
create policy "catalogo_admin" on ciudades       for all using (es_admin()) with check (es_admin());
create policy "catalogo_admin" on tipos_vehiculo for all using (es_admin()) with check (es_admin());
create policy "catalogo_admin" on rutas          for all using (es_admin()) with check (es_admin());
create policy "catalogo_admin" on tarifas        for all using (es_admin()) with check (es_admin());
create policy "catalogo_admin" on politicas_cancelacion for all using (es_admin()) with check (es_admin());

-- ---- Perfiles ----
create policy "perfil_propio_lectura" on perfiles for select using (id = auth.uid() or es_admin());
create policy "perfil_propio_update"  on perfiles for update using (id = auth.uid() or es_admin())
  with check ((id = auth.uid() and rol = rol_actual()) or es_admin());
  -- ↑ un usuario no puede cambiarse su propio rol
create policy "perfil_admin_all" on perfiles for all using (es_admin()) with check (es_admin());

-- ---- Conductores y vehículos ----
create policy "conductores_admin" on conductores for all using (es_admin()) with check (es_admin());
create policy "conductor_propio"  on conductores for select using (perfil_id = auth.uid());
create policy "conductor_propio_update" on conductores for update using (perfil_id = auth.uid())
  with check (perfil_id = auth.uid());
create policy "vehiculos_admin" on vehiculos for all using (es_admin()) with check (es_admin());
create policy "vehiculo_de_mi_conductor" on vehiculos for select using (conductor_id = conductor_actual_id());
-- (los datos del conductor/vehículo que ve el cliente salen por detalle_reserva(), que es security definer)

-- ---- Cupones: el cliente NO lista cupones; los valida por RPC ----
create policy "cupones_admin" on cupones for all using (es_admin()) with check (es_admin());
create policy "usos_cupon_propios" on usos_cupon for select using (cliente_id = auth.uid() or es_admin());

-- ---- Reservas ----
create policy "reservas_cliente_lectura"   on reservas for select using (cliente_id = auth.uid());
create policy "reservas_conductor_lectura" on reservas for select using (conductor_id = conductor_actual_id());
create policy "reservas_admin"             on reservas for all using (es_admin()) with check (es_admin());
-- Inserción/actualización del cliente SOLO por RPC (crear_reserva, cancelar_reserva) → sin policy de insert/update directo.

-- ---- Pasajeros ----
create policy "pasajeros_lectura" on pasajeros for select using (
  exists (select 1 from reservas r where r.id = reserva_id
          and (r.cliente_id = auth.uid() or r.conductor_id = conductor_actual_id())) or es_admin());
create policy "pasajeros_admin" on pasajeros for all using (es_admin()) with check (es_admin());
create policy "pasajeros_cliente_edit" on pasajeros for update using (
  exists (select 1 from reservas r where r.id = reserva_id and r.cliente_id = auth.uid()
          and r.estado in ('pendiente_pago','confirmada')));

-- ---- Historial ----
create policy "historial_lectura" on historial_estados for select using (
  exists (select 1 from reservas r where r.id = reserva_id
          and (r.cliente_id = auth.uid() or r.conductor_id = conductor_actual_id())) or es_admin());

-- ---- Pagos ----
create policy "pagos_lectura" on pagos for select using (
  exists (select 1 from reservas r where r.id = reserva_id and r.cliente_id = auth.uid()) or es_admin());
create policy "pagos_admin" on pagos for all using (es_admin()) with check (es_admin());

-- ---- Calificaciones ----
create policy "calif_lectura" on calificaciones for select using (
  cliente_id = auth.uid() or conductor_id = conductor_actual_id() or es_admin());
create policy "calif_admin" on calificaciones for all using (es_admin()) with check (es_admin());

-- ---- Soporte ----
create policy "soporte_cliente_lectura" on tickets_soporte for select using (cliente_id = auth.uid() or es_admin());
create policy "soporte_cliente_insert"  on tickets_soporte for insert with check (cliente_id = auth.uid());
create policy "soporte_admin"           on tickets_soporte for all using (es_admin()) with check (es_admin());

-- ---- Configuración: lectura pública de claves "publicas.*", resto admin ----
create policy "config_publica" on configuracion for select using (clave like 'publico.%' or es_admin());
create policy "config_admin"   on configuracion for all using (es_admin()) with check (es_admin());

-- ---- Ubicaciones GPS (fase 2) ----
create policy "gps_conductor_insert" on ubicaciones_conductor for insert with check (conductor_id = conductor_actual_id());
create policy "gps_lectura" on ubicaciones_conductor for select using (
  es_admin() or conductor_id = conductor_actual_id()
  or exists (select 1 from reservas r where r.id = reserva_id and r.cliente_id = auth.uid()
             and r.estado in ('en_camino','en_curso')));

-- ---- Permisos de ejecución de RPC ----
grant usage on schema public to anon, authenticated;
grant select on ciudades, tipos_vehiculo, rutas, tarifas, politicas_cancelacion, configuracion to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function cotizar(int,int,int,int) to anon, authenticated;
grant execute on all functions in schema public to authenticated;
revoke execute on function revisar_pago(uuid,boolean,text), asignar_conductor(uuid,uuid,uuid) from anon;


-- =====================================================================
-- 6. VISTAS PARA EL PANEL ADMIN
-- =====================================================================
create or replace view v_reservas_admin
with (security_invoker = true) as
select r.id, r.codigo, r.estado, r.fecha_viaje, r.hora_viaje, r.pasajeros, r.equipaje,
       r.precio_base, r.descuento, r.precio_total, r.moneda,
       co.nombre as origen, cd.nombre as destino, tv.nombre as tipo_vehiculo,
       p.nombre || ' ' || coalesce(p.apellido,'') as cliente, p.telefono as cliente_telefono, p.email as cliente_email,
       c.nombre as conductor, c.telefono as conductor_telefono,
       v.marca || ' ' || v.modelo || ' (' || v.placa || ')' as vehiculo,
       (select estado from pagos pg where pg.reserva_id = r.id order by creado_en desc limit 1) as estado_pago,
       r.creada_en, r.actualizada_en
from reservas r
join rutas ru on ru.id = r.ruta_id
join ciudades co on co.id = ru.origen_id
join ciudades cd on cd.id = ru.destino_id
join tipos_vehiculo tv on tv.id = r.tipo_vehiculo_id
join perfiles p on p.id = r.cliente_id
left join conductores c on c.id = r.conductor_id
left join vehiculos v on v.id = r.vehiculo_id;

create or replace view v_metricas_diarias
with (security_invoker = true) as
select fecha_viaje as fecha,
       count(*) as reservas,
       count(*) filter (where estado = 'completada') as completadas,
       count(*) filter (where estado in ('cancelada_cliente','cancelada_admin')) as canceladas,
       coalesce(sum(precio_total) filter (where estado not in ('cancelada_cliente','cancelada_admin','pendiente_pago')), 0) as ingresos,
       coalesce(sum(monto_reembolso), 0) as reembolsos
from reservas
group by fecha_viaje
order by fecha_viaje desc;

create or replace view v_rutas_populares
with (security_invoker = true) as
select co.nombre as origen, cd.nombre as destino, count(*) as reservas,
       coalesce(sum(r.precio_total) filter (where r.estado = 'completada'), 0) as ingresos
from reservas r
join rutas ru on ru.id = r.ruta_id
join ciudades co on co.id = ru.origen_id
join ciudades cd on cd.id = ru.destino_id
group by 1,2 order by reservas desc;

grant select on v_reservas_admin, v_metricas_diarias, v_rutas_populares to authenticated;
-- (security_invoker: aunque tengan grant, solo el admin ve filas gracias a las RLS de reservas)

-- KPIs de la pantalla principal del admin
create or replace function metricas_resumen()
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when es_admin() then jsonb_build_object(
    'reservas_hoy',        (select count(*) from reservas where fecha_viaje = current_date),
    'pendientes_pago',     (select count(*) from reservas where estado = 'pendiente_pago'),
    'pagos_por_verificar', (select count(*) from pagos where estado = 'verificando'),
    'por_asignar',         (select count(*) from reservas where estado = 'confirmada'),
    'en_curso',            (select count(*) from reservas where estado in ('en_camino','en_curso')),
    'ingresos_mes',        (select coalesce(sum(precio_total),0) from reservas
                             where estado = 'completada' and date_trunc('month', fecha_viaje) = date_trunc('month', current_date)),
    'clientes_total',      (select count(*) from perfiles where rol = 'cliente'),
    'conductores_activos', (select count(*) from conductores where activo),
    'calificacion_promedio', (select round(avg(puntuacion)::numeric,2) from calificaciones)
  ) else null end;
$$;


-- =====================================================================
-- 7. DATOS DE PRUEBA
-- =====================================================================

-- Ciudades (Caracas es el origen del MVP)
insert into ciudades (nombre, estado, orden) values
  ('Caracas', 'Distrito Capital', 1),
  ('Valencia', 'Carabobo', 10),
  ('Maracay', 'Aragua', 11),
  ('Puerto Cabello', 'Carabobo', 12),
  ('Barquisimeto', 'Lara', 20),
  ('Maracaibo', 'Zulia', 21),
  ('Barcelona', 'Anzoátegui', 30),
  ('Puerto La Cruz', 'Anzoátegui', 31),
  ('Mérida', 'Mérida', 40),
  ('San Cristóbal', 'Táchira', 41),
  ('Los Teques', 'Miranda', 50),
  ('La Guaira', 'La Guaira', 51)
on conflict (nombre) do nothing;

-- Tipos de vehículo
insert into tipos_vehiculo (codigo, nombre, descripcion, capacidad_pasajeros, capacidad_equipaje, icono, orden) values
  ('sedan', 'Sedán',      'Cómodo para hasta 4 pasajeros. Aire acondicionado.',            4, 3, '🚗', 1),
  ('suv',   'Camioneta',  'Más espacio y equipaje. Ideal para familias, hasta 6 pasajeros.', 6, 5, '🚙', 2),
  ('van',   'Van',        'Grupos grandes, hasta 12 pasajeros.',                          12, 12, '🚐', 3)
on conflict (codigo) do nothing;

-- Rutas desde Caracas (ida) y de regreso a Caracas
insert into rutas (origen_id, destino_id, distancia_km, duracion_min)
select c1.id, c2.id, d.km, d.min
from (values
  ('Valencia', 160, 150), ('Maracay', 115, 110), ('Puerto Cabello', 210, 190),
  ('Barquisimeto', 360, 330), ('Maracaibo', 700, 600), ('Barcelona', 320, 300),
  ('Puerto La Cruz', 330, 310), ('Mérida', 680, 660), ('San Cristóbal', 830, 780),
  ('Los Teques', 30, 45), ('La Guaira', 35, 45)
) as d(ciudad, km, min)
join ciudades c1 on c1.nombre = 'Caracas'
join ciudades c2 on c2.nombre = d.ciudad
on conflict do nothing;

insert into rutas (origen_id, destino_id, distancia_km, duracion_min)
select r.destino_id, r.origen_id, r.distancia_km, r.duracion_min
from rutas r join ciudades c on c.id = r.origen_id and c.nombre = 'Caracas'
on conflict do nothing;

-- Tarifas: precio TOTAL del vehículo (USD). Ej: Caracas–Valencia sedán = $80
insert into tarifas (ruta_id, tipo_vehiculo_id, precio_total)
select r.id, tv.id,
  case tv.codigo when 'sedan' then p.sedan when 'suv' then p.suv else p.van end
from (values
  ('Valencia', 80, 110, 180), ('Maracay', 60, 85, 140), ('Puerto Cabello', 100, 135, 220),
  ('Barquisimeto', 170, 230, 380), ('Maracaibo', 320, 420, 700), ('Barcelona', 150, 200, 340),
  ('Puerto La Cruz', 155, 205, 350), ('Mérida', 310, 410, 680), ('San Cristóbal', 380, 500, 820),
  ('Los Teques', 25, 35, 60), ('La Guaira', 25, 35, 60)
) as p(ciudad, sedan, suv, van)
join ciudades c on c.nombre = p.ciudad
join ciudades cc on cc.nombre = 'Caracas'
join rutas r on (r.origen_id = cc.id and r.destino_id = c.id) or (r.origen_id = c.id and r.destino_id = cc.id)
cross join tipos_vehiculo tv
on conflict do nothing;

-- Conductores de prueba (sin cuenta todavía; asignación manual)
insert into conductores (id, nombre, telefono, cedula, licencia, calificacion, total_viajes) values
  ('a1000000-0000-0000-0000-000000000001', 'Carlos Rodríguez', '0414-1234567', 'V-12345678', '5ta', 4.90, 120),
  ('a1000000-0000-0000-0000-000000000002', 'María Fernández',  '0424-7654321', 'V-23456789', '5ta', 4.80,  85),
  ('a1000000-0000-0000-0000-000000000003', 'José Martínez',    '0412-9988776', 'V-34567890', '5ta', 5.00,  40)
on conflict (id) do nothing;

-- Vehículos de prueba
insert into vehiculos (tipo_vehiculo_id, conductor_id, marca, modelo, anio, color, placa, capacidad_pasajeros)
select tv.id, v.conductor::uuid, v.marca, v.modelo, v.anio, v.color, v.placa, v.cap
from (values
  ('sedan', 'a1000000-0000-0000-0000-000000000001', 'Toyota',   'Corolla',  2019, 'Gris',   'AB123CD', 4),
  ('suv',   'a1000000-0000-0000-0000-000000000002', 'Toyota',   'Fortuner', 2020, 'Blanco', 'AC456DE', 6),
  ('van',   'a1000000-0000-0000-0000-000000000003', 'Hyundai',  'H1',       2018, 'Plata',  'AD789EF', 12)
) as v(tipo, conductor, marca, modelo, anio, color, placa, cap)
join tipos_vehiculo tv on tv.codigo = v.tipo
on conflict (placa) do nothing;

-- Cupones
insert into cupones (codigo, descripcion, tipo, valor, monto_minimo, max_usos, max_usos_por_usuario, vigente_hasta) values
  ('BIENVENIDO10', '10% de descuento en tu primer viaje', 'porcentaje', 10, 0, null, 1, now() + interval '1 year'),
  ('NOSFUIMOS20',  '$20 de descuento en viajes de $150 o más', 'monto_fijo', 20, 150, 100, 1, now() + interval '6 months')
on conflict (codigo) do nothing;

-- Política de cancelación por defecto
insert into politicas_cancelacion (nombre, horas_minimas, porcentaje_reembolso)
select * from (values
  ('Más de 24 h antes: reembolso total', 24, 100),
  ('Entre 6 y 24 h antes: 50%', 6, 50),
  ('Menos de 6 h: sin reembolso', 0, 0)
) as v(n, h, p)
where not exists (select 1 from politicas_cancelacion);

-- Configuración
insert into configuracion (clave, valor, descripcion) values
  ('publico.nombre_app',        '"Nos Fuimos"', 'Nombre visible de la app'),
  ('publico.moneda',            '"USD"', 'Moneda de las tarifas'),
  ('publico.horas_anticipacion', '2', 'Horas mínimas de anticipación para reservar'),
  ('publico.whatsapp_soporte',  '"+584141234567"', 'Número de soporte que ve el cliente'),
  ('publico.metodos_pago',      '["pago_movil","transferencia","zelle","efectivo"]', 'Métodos habilitados en la app'),
  ('publico.datos_pago',        '{"pago_movil":{"banco":"Banesco","cedula":"V-00000000","telefono":"0414-0000000"},"zelle":{"email":"pagos@nosfuimos.com"}}', 'Datos que se muestran al cliente para pagar'),
  ('asignacion_automatica',     'false', 'Fase 2: asignar conductor automáticamente')
on conflict (clave) do nothing;

-- =====================================================================
-- FIN. Siguiente paso: crea tu usuario en la app y conviértelo en admin:
--   update perfiles set rol = 'admin' where email = 'TU_CORREO@ejemplo.com';
-- =====================================================================
