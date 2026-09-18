-- =====================================================================
--  NOS FUIMOS — Migración 03: Traslado de paquetes (encomiendas)
--
--  Ejecutar DESPUÉS de 01 y 02 (Supabase → SQL Editor → Run).
--  Se puede volver a ejecutar sin romper nada.
--
--  Qué agrega:
--   - Tipo de vehículo "Camión" (uso = paquetes). Los camiones se registran
--     igual que los demás vehículos (conductor + vehículo) y NO aparecen
--     en la cotización de pasajeros.
--   - SALIDAS FIJAS: el administrador programa las fechas exactas en que
--     sale un camión por cada ruta (fecha, hora, hora límite para recibir
--     paquetes, capacidad). El cliente solo puede enviar en esas fechas.
--   - TARIFAS DE PAQUETES: el administrador define categorías por tamaño
--     y/o peso (Sobre, Pequeño, Mediano, Grande...) con su precio, para
--     todas las rutas o para una ruta específica, y elige el CRITERIO de
--     cobro: por tamaño, por peso o ambos (config 'publico.paquetes').
--   - Envíos (envios_paquetes) con código NP-XXXXXX, estados, historial,
--     pago con el mismo flujo de reservas (cliente reporta, admin aprueba).
--   - RPC: cotizar_paquete, salidas_disponibles, crear_envio,
--     registrar_pago_envio, cambiar_estado_envio, cancelar_envio,
--     detalle_envio, mis_envios. Vistas v_envios_admin, v_salidas_admin.
-- =====================================================================

-- ---------- 1. Tipos ----------
do $$ begin
  create type estado_envio as enum (
    'pendiente_pago',  -- creado, esperando pago
    'confirmado',      -- pago aprobado; el cliente debe llevar el paquete antes de la hora límite
    'recibido',        -- el paquete ya está en manos de Nos Fuimos
    'en_ruta',         -- el camión salió
    'llegado',         -- llegó a la ciudad destino, listo para entrega/retiro
    'entregado',
    'cancelado'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type estado_salida as enum ('programada', 'cerrada', 'en_ruta', 'completada', 'cancelada');
exception when duplicate_object then null; end $$;

do $$ begin
  create type criterio_paquete as enum ('tamano', 'peso', 'ambos');
exception when duplicate_object then null; end $$;

-- ---------- 2. Camión como tipo de vehículo ----------
alter table tipos_vehiculo add column if not exists uso text not null default 'pasajeros'; -- 'pasajeros' | 'paquetes'
alter table tipos_vehiculo add column if not exists capacidad_kg numeric(8,2);

insert into tipos_vehiculo (codigo, nombre, descripcion, capacidad_pasajeros, capacidad_equipaje, icono, orden, uso, capacidad_kg)
values ('camion', 'Camión', 'Traslado de paquetes y encomiendas entre ciudades.', 2, 0, '🚚', 10, 'paquetes', 3500)
on conflict (codigo) do update set uso = 'paquetes', icono = excluded.icono;

-- La cotización de pasajeros solo muestra vehículos de uso 'pasajeros'
create or replace function cotizar(
  p_origen_id int, p_destino_id int, p_pasajeros int default 1, p_equipaje int default 0
) returns table (
  ruta_id int, tipo_vehiculo_id int, codigo text, nombre text, descripcion text, icono text,
  capacidad_pasajeros int, capacidad_equipaje int, precio_total numeric, moneda text,
  distancia_km numeric, duracion_min int, disponible boolean, motivo text
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
  join tipos_vehiculo tv on tv.id = t.tipo_vehiculo_id and tv.activo and tv.uso = 'pasajeros'
  where r.origen_id = p_origen_id and r.destino_id = p_destino_id and r.activa
  order by tv.orden, t.precio_total;
$$;

-- ---------- 3. Tarifas de paquetes (las define el admin) ----------
-- Cada fila es una categoría: "Pequeño: hasta 5 kg y hasta 60 cm (largo+ancho+alto) → $8".
-- ruta_id null = aplica a todas las rutas. Si hay una tarifa específica para la ruta, gana.
create table if not exists tarifas_paquetes (
  id              serial primary key,
  ruta_id         int references rutas(id) on delete cascade,   -- null = todas las rutas
  nombre          text not null,                                 -- Sobre, Pequeño, Mediano, Grande
  descripcion     text,
  peso_max_kg     numeric(8,2),   -- null = sin límite de peso
  medida_max_cm   numeric(8,1),   -- suma largo+ancho+alto máxima; null = sin límite
  precio          numeric(10,2) not null check (precio >= 0),
  precio_kg_extra numeric(10,2) not null default 0,  -- por cada kg por encima de peso_max_kg (0 = no se permite exceder)
  moneda          text not null default 'USD',
  orden           int not null default 100,
  activa          boolean not null default true,
  creada_en       timestamptz not null default now()
);
create index if not exists tarifas_paquetes_ruta_idx on tarifas_paquetes(ruta_id);

-- ---------- 4. Salidas fijas de camiones (las programa el admin) ----------
create table if not exists salidas_paquetes (
  id                  serial primary key,
  ruta_id             int not null references rutas(id),
  fecha               date not null,
  hora_salida         time not null default '08:00',
  recepcion_hasta     timestamptz not null,       -- hasta cuándo se aceptan paquetes para esta salida
  punto_recepcion     text,                       -- dónde entrega el cliente el paquete (origen)
  punto_entrega       text,                       -- dónde se retira en destino (si no hay entrega a domicilio)
  entrega_domicilio   boolean not null default true,
  vehiculo_id         uuid references vehiculos(id),
  conductor_id        uuid references conductores(id),
  capacidad_kg        numeric(8,2),               -- null = sin límite
  capacidad_paquetes  int,                        -- null = sin límite
  estado              estado_salida not null default 'programada',
  notas               text,
  creada_en           timestamptz not null default now(),
  actualizada_en      timestamptz not null default now(),
  unique (ruta_id, fecha, hora_salida)
);
create index if not exists salidas_paquetes_fecha_idx on salidas_paquetes(fecha);

-- ---------- 5. Envíos ----------
create table if not exists envios_paquetes (
  id                  uuid primary key default gen_random_uuid(),
  codigo              text not null unique,                    -- NP-XXXXXX (trigger)
  cliente_id          uuid not null references perfiles(id),
  salida_id           int not null references salidas_paquetes(id),
  ruta_id             int not null references rutas(id),
  tarifa_id           int references tarifas_paquetes(id),
  -- el paquete
  descripcion         text not null,
  cantidad            int not null default 1 check (cantidad > 0),
  peso_kg             numeric(8,2),
  largo_cm            numeric(8,1),
  ancho_cm            numeric(8,1),
  alto_cm             numeric(8,1),
  valor_declarado     numeric(10,2),
  fragil              boolean not null default false,
  -- personas
  remitente_nombre    text not null,
  remitente_telefono  text not null,
  destinatario_nombre text not null,
  destinatario_telefono text not null,
  destinatario_cedula text,
  direccion_entrega   text,                                    -- null = retiro en punto de entrega
  notas               text,
  -- precio
  precio_base         numeric(10,2) not null,
  precio_extra        numeric(10,2) not null default 0,        -- kg extra
  precio_total        numeric(10,2) not null,
  moneda              text not null default 'USD',
  -- estado
  estado              estado_envio not null default 'pendiente_pago',
  recibido_en         timestamptz,
  entregado_en        timestamptz,
  entregado_a         text,
  cancelado_en        timestamptz,
  motivo_cancelacion  text,
  monto_reembolso     numeric(10,2),
  creado_en           timestamptz not null default now(),
  actualizado_en      timestamptz not null default now()
);
create index if not exists envios_cliente_idx on envios_paquetes(cliente_id);
create index if not exists envios_salida_idx  on envios_paquetes(salida_id);
create index if not exists envios_estado_idx  on envios_paquetes(estado);

create table if not exists historial_envios (
  id              bigserial primary key,
  envio_id        uuid not null references envios_paquetes(id) on delete cascade,
  estado_anterior estado_envio,
  estado_nuevo    estado_envio not null,
  cambiado_por    uuid references perfiles(id),
  comentario      text,
  creado_en       timestamptz not null default now()
);
create index if not exists historial_envios_idx on historial_envios(envio_id);

-- Pagos: ahora un pago puede ser de una reserva O de un envío
alter table pagos alter column reserva_id drop not null;
alter table pagos add column if not exists envio_id uuid references envios_paquetes(id) on delete cascade;
alter table pagos drop constraint if exists pagos_reserva_o_envio;
alter table pagos add constraint pagos_reserva_o_envio check (reserva_id is not null or envio_id is not null);
create index if not exists pagos_envio_idx on pagos(envio_id);

-- ---------- 6. Triggers ----------
do $$
declare t text;
begin
  foreach t in array array['salidas_paquetes','envios_paquetes'] loop
    execute format('drop trigger if exists trg_%s_actualizado on %I', t, t);
    execute format('create trigger trg_%s_actualizado before update on %I for each row execute function set_actualizado_en()', t, t);
  end loop;
end $$;

create or replace function generar_codigo_envio() returns text
language plpgsql as $$
declare alfabeto text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; v text; i int;
begin
  loop
    v := 'NP-';
    for i in 1..6 loop v := v || substr(alfabeto, 1 + floor(random() * length(alfabeto))::int, 1); end loop;
    exit when not exists (select 1 from envios_paquetes e where e.codigo = v);
  end loop;
  return v;
end $$;

create or replace function asignar_codigo_envio() returns trigger
language plpgsql as $$
begin
  if new.codigo is null or new.codigo = '' then new.codigo := generar_codigo_envio(); end if;
  return new;
end $$;
drop trigger if exists trg_envios_codigo on envios_paquetes;
create trigger trg_envios_codigo before insert on envios_paquetes for each row execute function asignar_codigo_envio();

create or replace function registrar_cambio_estado_envio() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into historial_envios (envio_id, estado_anterior, estado_nuevo, cambiado_por) values (new.id, null, new.estado, auth.uid());
  elsif new.estado is distinct from old.estado then
    insert into historial_envios (envio_id, estado_anterior, estado_nuevo, cambiado_por) values (new.id, old.estado, new.estado, auth.uid());
  end if;
  return new;
end $$;
drop trigger if exists trg_envios_historial on envios_paquetes;
create trigger trg_envios_historial after insert or update on envios_paquetes for each row execute function registrar_cambio_estado_envio();

-- ---------- 7. Configuración ----------
-- criterio: 'tamano' (solo medidas), 'peso' (solo kg) o 'ambos' (la categoría debe cumplir peso Y medidas)
insert into configuracion (clave, valor, descripcion) values
  ('publico.paquetes',
   '{"activo": true, "criterio": "ambos", "horas_limite_recepcion": 3,
     "punto_recepcion": "Oficina Nos Fuimos, Caracas",
     "texto_cliente": "Lleva tu paquete al punto de recepción antes de la hora límite de la salida que elijas. Te avisamos por WhatsApp cuando llegue a destino."}',
   'Módulo de paquetes: criterio de cobro (tamano | peso | ambos), horas antes de la salida en que cierra la recepción, textos')
on conflict (clave) do nothing;

create or replace function paquetes_criterio() returns criterio_paquete
language sql stable security definer set search_path = public as $$
  select coalesce((select (valor->>'criterio')::criterio_paquete from configuracion where clave = 'publico.paquetes'), 'ambos');
$$;

-- ---------- 8. RPC ----------

-- 8.1 Salidas disponibles para una ruta (fechas fijas futuras que aún reciben paquetes)
create or replace function salidas_disponibles(p_origen_id int, p_destino_id int)
returns table (
  salida_id int, ruta_id int, fecha date, hora_salida time, recepcion_hasta timestamptz,
  punto_recepcion text, punto_entrega text, entrega_domicilio boolean,
  cupos_paquetes int, kg_disponibles numeric, vehiculo text
)
language sql stable security definer set search_path = public as $$
  select s.id, s.ruta_id, s.fecha, s.hora_salida, s.recepcion_hasta,
         coalesce(s.punto_recepcion, (select valor->>'punto_recepcion' from configuracion where clave = 'publico.paquetes')),
         s.punto_entrega, s.entrega_domicilio,
         case when s.capacidad_paquetes is null then null
              else s.capacidad_paquetes - (select coalesce(sum(e.cantidad),0) from envios_paquetes e where e.salida_id = s.id and e.estado not in ('cancelado'))::int end,
         case when s.capacidad_kg is null then null
              else s.capacidad_kg - (select coalesce(sum(e.peso_kg * e.cantidad),0) from envios_paquetes e where e.salida_id = s.id and e.estado not in ('cancelado')) end,
         (select v.marca || ' ' || v.modelo from vehiculos v where v.id = s.vehiculo_id)
  from salidas_paquetes s
  join rutas r on r.id = s.ruta_id
  where r.origen_id = p_origen_id and r.destino_id = p_destino_id
    and s.estado = 'programada' and s.recepcion_hasta > now()
  order by s.fecha, s.hora_salida;
$$;

-- 8.2 Cotizar un paquete: elige la categoría más barata que cumpla según el criterio configurado
create or replace function cotizar_paquete(
  p_origen_id int, p_destino_id int,
  p_peso_kg numeric default null, p_largo_cm numeric default null, p_ancho_cm numeric default null, p_alto_cm numeric default null,
  p_cantidad int default 1
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_ruta_id int; v_crit criterio_paquete := paquetes_criterio();
  v_medida numeric := coalesce(p_largo_cm,0) + coalesce(p_ancho_cm,0) + coalesce(p_alto_cm,0);
  t record; v_extra numeric := 0; v_kg_extra numeric := 0;
  v_cats jsonb;
begin
  select id into v_ruta_id from rutas where origen_id = p_origen_id and destino_id = p_destino_id and activa;
  if v_ruta_id is null then return jsonb_build_object('ok', false, 'mensaje', 'Ruta no disponible'); end if;
  if v_crit in ('peso','ambos') and coalesce(p_peso_kg,0) <= 0 then return jsonb_build_object('ok', false, 'mensaje', 'Indica el peso del paquete'); end if;
  if v_crit in ('tamano','ambos') and v_medida <= 0 then return jsonb_build_object('ok', false, 'mensaje', 'Indica las medidas del paquete'); end if;

  -- categorías aplicables (ruta específica o generales); si hay específicas de la ruta, se usan solo esas
  with base as (
    select * from tarifas_paquetes tp where tp.activa and (tp.ruta_id = v_ruta_id or tp.ruta_id is null)
  ), esp as (select * from base where ruta_id = v_ruta_id),
  usar as (select * from esp union all select * from base where ruta_id is null and not exists (select 1 from esp))
  select jsonb_agg(to_jsonb(u) order by u.orden, u.precio) into v_cats from usar u;

  -- la categoría que cumple con el precio final más bajo (incluyendo kg extra si la categoría lo permite)
  select * into t from (
    select u.*,
           u.precio + case when v_crit <> 'tamano' and u.peso_max_kg is not null and p_peso_kg > u.peso_max_kg
                           then ceil(p_peso_kg - u.peso_max_kg) * u.precio_kg_extra else 0 end as precio_final
    from jsonb_populate_recordset(null::tarifas_paquetes, coalesce(v_cats,'[]'::jsonb)) u
    where (v_crit = 'peso'   or u.medida_max_cm is null or v_medida <= u.medida_max_cm)
      and (v_crit = 'tamano' or u.peso_max_kg is null or p_peso_kg <= u.peso_max_kg or u.precio_kg_extra > 0)
    order by precio_final, u.orden limit 1
  ) x;

  if not found then
    return jsonb_build_object('ok', false, 'mensaje', 'El paquete excede las categorías disponibles. Escríbenos por WhatsApp para cotizarlo.', 'categorias', coalesce(v_cats,'[]'::jsonb));
  end if;

  if v_crit <> 'tamano' and t.peso_max_kg is not null and p_peso_kg > t.peso_max_kg then
    v_kg_extra := ceil(p_peso_kg - t.peso_max_kg); v_extra := v_kg_extra * t.precio_kg_extra;
  end if;

  return jsonb_build_object(
    'ok', true, 'ruta_id', v_ruta_id, 'criterio', v_crit,
    'tarifa_id', t.id, 'categoria', t.nombre, 'descripcion', t.descripcion,
    'precio_unitario', t.precio + v_extra, 'precio_base', t.precio * greatest(p_cantidad,1),
    'precio_extra', v_extra * greatest(p_cantidad,1), 'kg_extra', v_kg_extra,
    'precio_total', (t.precio + v_extra) * greatest(p_cantidad,1), 'moneda', t.moneda,
    'categorias', coalesce(v_cats,'[]'::jsonb)
  );
end $$;

-- 8.3 Crear envío (precio calculado en el servidor)
create or replace function crear_envio(
  p_salida_id int,
  p_descripcion text,
  p_remitente_nombre text, p_remitente_telefono text,
  p_destinatario_nombre text, p_destinatario_telefono text,
  p_peso_kg numeric default null, p_largo_cm numeric default null, p_ancho_cm numeric default null, p_alto_cm numeric default null,
  p_cantidad int default 1,
  p_valor_declarado numeric default null, p_fragil boolean default false,
  p_destinatario_cedula text default null, p_direccion_entrega text default null, p_notas text default null
) returns envios_paquetes
language plpgsql security definer set search_path = public as $$
declare s salidas_paquetes%rowtype; r rutas%rowtype; c jsonb; e envios_paquetes%rowtype; v_cupos int; v_kg numeric;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if coalesce(trim(p_descripcion),'') = '' then raise exception 'Describe el contenido del paquete'; end if;
  if coalesce(trim(p_destinatario_nombre),'') = '' or coalesce(trim(p_destinatario_telefono),'') = '' then raise exception 'Indica nombre y teléfono del destinatario'; end if;

  select * into s from salidas_paquetes where id = p_salida_id;
  if not found then raise exception 'Salida no encontrada'; end if;
  if s.estado <> 'programada' then raise exception 'Esta salida ya no acepta paquetes'; end if;
  if s.recepcion_hasta < now() then raise exception 'Cerró la recepción de paquetes para esta salida'; end if;
  if s.capacidad_paquetes is not null then
    select s.capacidad_paquetes - coalesce(sum(cantidad),0) into v_cupos from envios_paquetes where salida_id = s.id and estado <> 'cancelado';
    if v_cupos < greatest(p_cantidad,1) then raise exception 'No hay cupo suficiente en esta salida (quedan %)', v_cupos; end if;
  end if;
  if s.capacidad_kg is not null and p_peso_kg is not null then
    select s.capacidad_kg - coalesce(sum(peso_kg * cantidad),0) into v_kg from envios_paquetes where salida_id = s.id and estado <> 'cancelado';
    if v_kg < p_peso_kg * greatest(p_cantidad,1) then raise exception 'El camión no tiene capacidad de peso suficiente en esta salida'; end if;
  end if;
  if not s.entrega_domicilio and p_direccion_entrega is not null then p_direccion_entrega := null; end if;

  select * into r from rutas where id = s.ruta_id;
  c := cotizar_paquete(r.origen_id, r.destino_id, p_peso_kg, p_largo_cm, p_ancho_cm, p_alto_cm, p_cantidad);
  if not (c->>'ok')::boolean then raise exception '%', c->>'mensaje'; end if;

  insert into envios_paquetes (cliente_id, salida_id, ruta_id, tarifa_id, descripcion, cantidad, peso_kg, largo_cm, ancho_cm, alto_cm,
    valor_declarado, fragil, remitente_nombre, remitente_telefono, destinatario_nombre, destinatario_telefono, destinatario_cedula,
    direccion_entrega, notas, precio_base, precio_extra, precio_total, moneda, estado)
  values (auth.uid(), s.id, s.ruta_id, (c->>'tarifa_id')::int, trim(p_descripcion), greatest(p_cantidad,1), p_peso_kg, p_largo_cm, p_ancho_cm, p_alto_cm,
    p_valor_declarado, coalesce(p_fragil,false), trim(p_remitente_nombre), trim(p_remitente_telefono), trim(p_destinatario_nombre), trim(p_destinatario_telefono), p_destinatario_cedula,
    p_direccion_entrega, p_notas, (c->>'precio_base')::numeric, (c->>'precio_extra')::numeric, (c->>'precio_total')::numeric, c->>'moneda', 'pendiente_pago')
  returning * into e;
  return e;
end $$;

-- 8.4 Registrar pago de un envío (cliente reporta)
create or replace function registrar_pago_envio(
  p_envio_id uuid, p_metodo metodo_pago, p_referencia text, p_monto numeric,
  p_comprobante_url text default null, p_proveedor text default 'manual'
) returns pagos
language plpgsql security definer set search_path = public as $$
declare e envios_paquetes%rowtype; p pagos%rowtype;
begin
  select * into e from envios_paquetes where id = p_envio_id;
  if not found then raise exception 'Envío no encontrado'; end if;
  if e.cliente_id <> auth.uid() and not es_admin() then raise exception 'Sin permiso'; end if;
  if e.estado <> 'pendiente_pago' then raise exception 'El envío no está pendiente de pago'; end if;
  insert into pagos (envio_id, metodo, proveedor, referencia, monto, comprobante_url, estado)
  values (p_envio_id, p_metodo, p_proveedor, p_referencia, p_monto, p_comprobante_url, 'verificando')
  returning * into p;
  return p;
end $$;

-- 8.5 revisar_pago ahora también confirma envíos
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
    if v_pago.reserva_id is not null then
      update reservas set estado = 'confirmada' where id = v_pago.reserva_id and estado = 'pendiente_pago';
    end if;
    if v_pago.envio_id is not null then
      update envios_paquetes set estado = 'confirmado' where id = v_pago.envio_id and estado = 'pendiente_pago';
    end if;
  end if;
  return v_pago;
end $$;

-- 8.6 Cambiar estado del envío (admin, o conductor de la salida)
create or replace function cambiar_estado_envio(p_envio_id uuid, p_estado estado_envio, p_comentario text default null, p_entregado_a text default null)
returns envios_paquetes
language plpgsql security definer set search_path = public as $$
declare e envios_paquetes%rowtype; s salidas_paquetes%rowtype;
begin
  select * into e from envios_paquetes where id = p_envio_id;
  if not found then raise exception 'Envío no encontrado'; end if;
  select * into s from salidas_paquetes where id = e.salida_id;
  if not es_admin() and (s.conductor_id is null or s.conductor_id <> conductor_actual_id()) then raise exception 'Sin permiso'; end if;
  if not es_admin() and p_estado not in ('en_ruta','llegado','entregado') then raise exception 'Transición no permitida'; end if;
  update envios_paquetes
     set estado = p_estado,
         recibido_en  = case when p_estado = 'recibido'  then now() else recibido_en end,
         entregado_en = case when p_estado = 'entregado' then now() else entregado_en end,
         entregado_a  = coalesce(p_entregado_a, entregado_a)
   where id = p_envio_id returning * into e;
  if p_comentario is not null then
    update historial_envios set comentario = p_comentario where id = (select max(id) from historial_envios where envio_id = p_envio_id);
  end if;
  return e;
end $$;

-- 8.7 Cambiar estado de una SALIDA y propagar a sus envíos (admin o conductor asignado)
create or replace function cambiar_estado_salida(p_salida_id int, p_estado estado_salida)
returns salidas_paquetes
language plpgsql security definer set search_path = public as $$
declare s salidas_paquetes%rowtype;
begin
  select * into s from salidas_paquetes where id = p_salida_id;
  if not found then raise exception 'Salida no encontrada'; end if;
  if not es_admin() and (s.conductor_id is null or s.conductor_id <> conductor_actual_id()) then raise exception 'Sin permiso'; end if;
  update salidas_paquetes set estado = p_estado where id = p_salida_id returning * into s;
  if p_estado = 'en_ruta' then
    update envios_paquetes set estado = 'en_ruta' where salida_id = p_salida_id and estado = 'recibido';
  elsif p_estado = 'completada' then
    update envios_paquetes set estado = 'llegado' where salida_id = p_salida_id and estado = 'en_ruta';
  elsif p_estado = 'cancelada' then
    update envios_paquetes set estado = 'cancelado', cancelado_en = now(), motivo_cancelacion = 'Salida cancelada por Nos Fuimos',
           monto_reembolso = case when estado in ('confirmado','recibido') then precio_total else 0 end
     where salida_id = p_salida_id and estado in ('pendiente_pago','confirmado','recibido');
  end if;
  return s;
end $$;

-- 8.8 Cancelar envío (cliente antes de entregar el paquete, o admin). Reembolso total si ya pagó y no ha salido.
create or replace function cancelar_envio(p_envio_id uuid, p_motivo text default null)
returns envios_paquetes
language plpgsql security definer set search_path = public as $$
declare e envios_paquetes%rowtype; v_monto numeric := 0;
begin
  select * into e from envios_paquetes where id = p_envio_id;
  if not found then raise exception 'Envío no encontrado'; end if;
  if e.cliente_id <> auth.uid() and not es_admin() then raise exception 'Sin permiso'; end if;
  if e.estado in ('en_ruta','llegado','entregado','cancelado') then raise exception 'Este envío ya no se puede cancelar (estado: %)', e.estado; end if;
  if e.estado <> 'pendiente_pago' and not es_admin() and e.estado = 'recibido' then raise exception 'El paquete ya fue recibido; contacta a soporte para cancelar'; end if;
  if e.estado in ('confirmado','recibido') then v_monto := e.precio_total; end if;
  update envios_paquetes set estado = 'cancelado', cancelado_en = now(), motivo_cancelacion = p_motivo, monto_reembolso = v_monto
   where id = p_envio_id returning * into e;
  if v_monto > 0 then update pagos set estado = 'reembolsado' where envio_id = p_envio_id and estado = 'aprobado'; end if;
  return e;
end $$;

-- 8.9 Detalle de un envío
create or replace function detalle_envio(p_envio_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'envio', to_jsonb(e),
    'origen', co.nombre, 'destino', cd.nombre,
    'salida', jsonb_build_object('id', s.id, 'fecha', s.fecha, 'hora_salida', s.hora_salida, 'recepcion_hasta', s.recepcion_hasta,
                                 'punto_recepcion', coalesce(s.punto_recepcion, (select valor->>'punto_recepcion' from configuracion where clave='publico.paquetes')),
                                 'punto_entrega', s.punto_entrega, 'entrega_domicilio', s.entrega_domicilio, 'estado', s.estado),
    'categoria', (select nombre from tarifas_paquetes where id = e.tarifa_id),
    'conductor', case when e.estado in ('en_ruta','llegado','entregado') and c.id is not null
                      then jsonb_build_object('nombre', c.nombre, 'telefono', c.telefono) else null end,
    'vehiculo', case when v.id is not null then jsonb_build_object('marca', v.marca, 'modelo', v.modelo, 'placa', v.placa) else null end,
    'pagos', (select coalesce(jsonb_agg(to_jsonb(pg) order by pg.creado_en), '[]'::jsonb) from pagos pg where pg.envio_id = e.id),
    'historial', (select coalesce(jsonb_agg(jsonb_build_object('estado', h.estado_nuevo, 'fecha', h.creado_en, 'comentario', h.comentario) order by h.creado_en), '[]'::jsonb)
                  from historial_envios h where h.envio_id = e.id)
  )
  from envios_paquetes e
  join salidas_paquetes s on s.id = e.salida_id
  join rutas ru on ru.id = e.ruta_id
  join ciudades co on co.id = ru.origen_id
  join ciudades cd on cd.id = ru.destino_id
  left join conductores c on c.id = s.conductor_id
  left join vehiculos v on v.id = s.vehiculo_id
  where e.id = p_envio_id
    and (e.cliente_id = auth.uid() or es_admin() or s.conductor_id = conductor_actual_id());
$$;

-- 8.10 Mis envíos (cliente)
create or replace function mis_envios()
returns table (id uuid, codigo text, estado estado_envio, descripcion text, cantidad int, precio_total numeric,
               origen text, destino text, fecha date, hora_salida time, destinatario_nombre text, creado_en timestamptz)
language sql stable security definer set search_path = public as $$
  select e.id, e.codigo, e.estado, e.descripcion, e.cantidad, e.precio_total, co.nombre, cd.nombre, s.fecha, s.hora_salida, e.destinatario_nombre, e.creado_en
  from envios_paquetes e
  join salidas_paquetes s on s.id = e.salida_id
  join rutas ru on ru.id = e.ruta_id join ciudades co on co.id = ru.origen_id join ciudades cd on cd.id = ru.destino_id
  where e.cliente_id = auth.uid()
  order by s.fecha desc, e.creado_en desc;
$$;

-- 8.11 Rastreo público por código (sin sesión): solo estado y ruta, nada personal
create or replace function rastrear_envio(p_codigo text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('codigo', e.codigo, 'estado', e.estado, 'origen', co.nombre, 'destino', cd.nombre,
                            'fecha_salida', s.fecha, 'hora_salida', s.hora_salida, 'entregado_en', e.entregado_en,
                            'historial', (select coalesce(jsonb_agg(jsonb_build_object('estado', h.estado_nuevo, 'fecha', h.creado_en) order by h.creado_en), '[]'::jsonb) from historial_envios h where h.envio_id = e.id))
  from envios_paquetes e join salidas_paquetes s on s.id = e.salida_id
  join rutas ru on ru.id = e.ruta_id join ciudades co on co.id = ru.origen_id join ciudades cd on cd.id = ru.destino_id
  where upper(e.codigo) = upper(trim(p_codigo));
$$;

-- ---------- 9. RLS ----------
alter table tarifas_paquetes enable row level security;
alter table salidas_paquetes enable row level security;
alter table envios_paquetes  enable row level security;
alter table historial_envios enable row level security;

drop policy if exists "tarifas_paq_lectura" on tarifas_paquetes;
drop policy if exists "tarifas_paq_admin"   on tarifas_paquetes;
create policy "tarifas_paq_lectura" on tarifas_paquetes for select using (true);
create policy "tarifas_paq_admin"   on tarifas_paquetes for all using (es_admin()) with check (es_admin());

drop policy if exists "salidas_lectura"   on salidas_paquetes;
drop policy if exists "salidas_admin"     on salidas_paquetes;
drop policy if exists "salidas_conductor" on salidas_paquetes;
create policy "salidas_lectura"   on salidas_paquetes for select using (true);
create policy "salidas_admin"     on salidas_paquetes for all using (es_admin()) with check (es_admin());

drop policy if exists "envios_cliente"   on envios_paquetes;
drop policy if exists "envios_conductor" on envios_paquetes;
drop policy if exists "envios_admin"     on envios_paquetes;
create policy "envios_cliente"   on envios_paquetes for select using (cliente_id = auth.uid());
create policy "envios_conductor" on envios_paquetes for select using (
  exists (select 1 from salidas_paquetes s where s.id = salida_id and s.conductor_id = conductor_actual_id()));
create policy "envios_admin"     on envios_paquetes for all using (es_admin()) with check (es_admin());
-- (inserción/actualización del cliente solo por RPC)

drop policy if exists "hist_envios_lectura" on historial_envios;
create policy "hist_envios_lectura" on historial_envios for select using (
  es_admin() or exists (select 1 from envios_paquetes e where e.id = envio_id and e.cliente_id = auth.uid()));

-- pagos: el cliente también ve los pagos de sus envíos
drop policy if exists "pagos_lectura" on pagos;
create policy "pagos_lectura" on pagos for select using (
  es_admin()
  or exists (select 1 from reservas r where r.id = reserva_id and r.cliente_id = auth.uid())
  or exists (select 1 from envios_paquetes e where e.id = envio_id and e.cliente_id = auth.uid()));

grant select on tarifas_paquetes, salidas_paquetes to anon, authenticated;
grant select, insert, update, delete on tarifas_paquetes, salidas_paquetes, envios_paquetes, historial_envios to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
grant execute on function cotizar(int,int,int,int), salidas_disponibles(int,int), rastrear_envio(text),
                          cotizar_paquete(int,int,numeric,numeric,numeric,numeric,int) to anon;

-- ---------- 10. Vistas admin ----------
create or replace view v_salidas_admin
with (security_invoker = true) as
select s.*, co.nombre as origen, cd.nombre as destino,
       c.nombre as conductor, c.telefono as conductor_telefono,
       v.marca || ' ' || v.modelo || ' (' || v.placa || ')' as vehiculo,
       (select count(*) from envios_paquetes e where e.salida_id = s.id and e.estado <> 'cancelado') as envios,
       (select coalesce(sum(e.cantidad),0) from envios_paquetes e where e.salida_id = s.id and e.estado <> 'cancelado') as paquetes,
       (select coalesce(sum(e.peso_kg * e.cantidad),0) from envios_paquetes e where e.salida_id = s.id and e.estado <> 'cancelado') as kg,
       (select coalesce(sum(e.precio_total),0) from envios_paquetes e where e.salida_id = s.id and e.estado not in ('cancelado','pendiente_pago')) as ingresos
from salidas_paquetes s
join rutas ru on ru.id = s.ruta_id
join ciudades co on co.id = ru.origen_id
join ciudades cd on cd.id = ru.destino_id
left join conductores c on c.id = s.conductor_id
left join vehiculos v on v.id = s.vehiculo_id;

create or replace view v_envios_admin
with (security_invoker = true) as
select e.id, e.codigo, e.estado, e.descripcion, e.cantidad, e.peso_kg, e.largo_cm, e.ancho_cm, e.alto_cm, e.fragil, e.valor_declarado,
       e.precio_total, e.moneda, e.remitente_nombre, e.remitente_telefono, e.destinatario_nombre, e.destinatario_telefono, e.direccion_entrega,
       e.salida_id, s.fecha, s.hora_salida, s.recepcion_hasta, co.nombre as origen, cd.nombre as destino,
       p.nombre || ' ' || coalesce(p.apellido,'') as cliente, p.telefono as cliente_telefono, p.email as cliente_email,
       (select nombre from tarifas_paquetes t where t.id = e.tarifa_id) as categoria,
       (select estado from pagos pg where pg.envio_id = e.id order by creado_en desc limit 1) as estado_pago,
       e.creado_en, e.actualizado_en
from envios_paquetes e
join salidas_paquetes s on s.id = e.salida_id
join rutas ru on ru.id = e.ruta_id
join ciudades co on co.id = ru.origen_id
join ciudades cd on cd.id = ru.destino_id
join perfiles p on p.id = e.cliente_id;

grant select on v_salidas_admin, v_envios_admin to authenticated;

-- KPIs: agregar métricas de paquetes
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
                             where estado = 'completada' and date_trunc('month', fecha_viaje) = date_trunc('month', current_date))
                         + (select coalesce(sum(precio_total),0) from envios_paquetes
                             where estado = 'entregado' and date_trunc('month', entregado_en) = date_trunc('month', current_date)),
    'clientes_total',      (select count(*) from perfiles where rol = 'cliente'),
    'conductores_activos', (select count(*) from conductores where activo),
    'calificacion_promedio', (select round(avg(puntuacion)::numeric,2) from calificaciones),
    'paquetes_por_recibir', (select count(*) from envios_paquetes where estado = 'confirmado'),
    'paquetes_en_ruta',     (select count(*) from envios_paquetes where estado in ('en_ruta','llegado')),
    'salidas_proximas',     (select count(*) from salidas_paquetes where estado = 'programada' and fecha >= current_date)
  ) else null end;
$$;

-- ---------- 11. Datos de prueba ----------
-- Categorías generales (todas las rutas). El admin las puede editar o crear por ruta.
insert into tarifas_paquetes (nombre, descripcion, peso_max_kg, medida_max_cm, precio, precio_kg_extra, orden)
select * from (values
  ('Sobre',    'Documentos y sobres',                      1,    60,   5,  0, 1),
  ('Pequeño',  'Caja de zapatos o similar',                5,    90,   8,  0, 2),
  ('Mediano',  'Caja mediana',                             15,   150, 15,  0, 3),
  ('Grande',   'Caja grande o bulto',                      30,   220, 25,  1, 4),
  ('Extra',    'Bultos pesados (se cobra por kg adicional)', 60, 300, 40,  1, 5)
) as v(n, d, p, m, pr, ex, o)
where not exists (select 1 from tarifas_paquetes);

-- Camión de prueba con conductor
insert into conductores (id, nombre, telefono, cedula, licencia, estado, calificacion, total_viajes) values
  ('a1000000-0000-0000-0000-000000000004', 'Pedro Gómez', '0416-5551234', 'V-45678901', '5ta', 'aprobado', 5.00, 30)
on conflict (id) do nothing;
insert into vehiculos (tipo_vehiculo_id, conductor_id, marca, modelo, anio, color, placa, capacidad_pasajeros)
select tv.id, 'a1000000-0000-0000-0000-000000000004', 'Chevrolet', 'NPR', 2019, 'Blanco', 'A55BC7D', 2
from tipos_vehiculo tv where tv.codigo = 'camion'
on conflict (placa) do nothing;

-- Salidas de ejemplo: próximos 3 lunes y jueves Caracas → Valencia y regreso
insert into salidas_paquetes (ruta_id, fecha, hora_salida, recepcion_hasta, punto_recepcion, punto_entrega, entrega_domicilio, vehiculo_id, conductor_id, capacidad_kg, capacidad_paquetes)
select r.id, d::date, '08:00', (d::date + time '05:00')::timestamptz, 'Oficina Nos Fuimos, Caracas', 'Punto de retiro en ' || cd.nombre, true,
       (select id from vehiculos where placa = 'A55BC7D'), 'a1000000-0000-0000-0000-000000000004', 3000, 80
from rutas r
join ciudades co on co.id = r.origen_id join ciudades cd on cd.id = r.destino_id
cross join generate_series(current_date + 1, current_date + 21, interval '1 day') d
where ((co.nombre = 'Caracas' and cd.nombre = 'Valencia') or (co.nombre = 'Valencia' and cd.nombre = 'Caracas'))
  and extract(isodow from d) in (1, 4)
on conflict do nothing;

-- =====================================================================
-- FIN. En el panel admin → 📦 Paquetes puedes: programar salidas, definir
-- tarifas por tamaño/peso, elegir el criterio de cobro y gestionar envíos.
-- =====================================================================
