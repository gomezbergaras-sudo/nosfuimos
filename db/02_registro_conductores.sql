-- =====================================================================
--  NOS FUIMOS — Migración 02: Registro de conductores y documentos
--
--  Ejecutar DESPUÉS de 01_esquema_nos_fuimos.sql (SQL Editor → Run).
--  Se puede volver a ejecutar sin romper nada.
--
--  Qué agrega:
--   - Estado de aprobación del conductor (pendiente / aprobado / rechazado / suspendido)
--   - Datos adicionales del conductor y del vehículo (año, condiciones, etc.)
--   - Tabla documentos_conductor (licencia, RCV, certificado médico, ...)
--   - Bucket privado "documentos" en Supabase Storage + políticas
--   - RPC registrar_conductor (autoservicio desde la app del conductor)
--   - RPC revisar_conductor y revisar_documento (admin)
--   - asignar_conductor ahora exige conductor aprobado
-- =====================================================================

-- ---------- 1. Tipos ----------
do $$ begin
  create type estado_conductor as enum ('pendiente', 'aprobado', 'rechazado', 'suspendido');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_documento as enum (
    'cedula', 'licencia', 'certificado_medico', 'rcv', 'carnet_circulacion',
    'antecedentes', 'foto_vehiculo', 'foto_conductor', 'otro');
exception when duplicate_object then null; end $$;

do $$ begin
  create type estado_documento as enum ('pendiente', 'aprobado', 'rechazado', 'vencido');
exception when duplicate_object then null; end $$;

-- ---------- 2. Columnas nuevas ----------
alter table conductores
  add column if not exists estado            estado_conductor not null default 'pendiente',
  add column if not exists email             text,
  add column if not exists fecha_nacimiento  date,
  add column if not exists direccion         text,
  add column if not exists ciudad_base_id    int references ciudades(id),
  add column if not exists anios_experiencia int,
  add column if not exists licencia_grado    text,      -- 3ra, 4ta, 5ta
  add column if not exists licencia_vence    date,
  add column if not exists observacion_admin text,
  add column if not exists revisado_por      uuid references perfiles(id),
  add column if not exists revisado_en       timestamptz;

-- los conductores de prueba del script 01 quedan aprobados
update conductores set estado = 'aprobado'
 where estado = 'pendiente' and (perfil_id is null or id in ('a1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000003'));

alter table vehiculos
  add column if not exists aire_acondicionado boolean not null default true,
  add column if not exists condicion         text,      -- excelente / buena / regular
  add column if not exists kilometraje       int,
  add column if not exists rcv_vence         date,
  add column if not exists notas             text;

-- ---------- 3. Documentos ----------
create table if not exists documentos_conductor (
  id             uuid primary key default gen_random_uuid(),
  conductor_id   uuid not null references conductores(id) on delete cascade,
  tipo           tipo_documento not null,
  archivo_path   text not null,          -- ruta dentro del bucket "documentos"
  nombre_archivo text,
  vence_el       date,
  estado         estado_documento not null default 'pendiente',
  observacion    text,
  revisado_por   uuid references perfiles(id),
  revisado_en    timestamptz,
  subido_en      timestamptz not null default now()
);
create index if not exists documentos_conductor_idx on documentos_conductor(conductor_id, tipo);
grant select, insert, update, delete on documentos_conductor to authenticated;

-- Documentos obligatorios (configurable por el admin)
insert into configuracion (clave, valor, descripcion) values
  ('publico.documentos_conductor',
   '[{"tipo":"cedula","nombre":"Cédula de identidad","obligatorio":true,"vence":false},
     {"tipo":"licencia","nombre":"Licencia de conducir (5ta)","obligatorio":true,"vence":true},
     {"tipo":"certificado_medico","nombre":"Certificado médico vigente","obligatorio":true,"vence":true},
     {"tipo":"rcv","nombre":"Póliza RCV del vehículo","obligatorio":true,"vence":true},
     {"tipo":"carnet_circulacion","nombre":"Carnet de circulación","obligatorio":true,"vence":false},
     {"tipo":"foto_conductor","nombre":"Foto del conductor (rostro)","obligatorio":true,"vence":false},
     {"tipo":"foto_vehiculo","nombre":"Foto del vehículo","obligatorio":true,"vence":false},
     {"tipo":"antecedentes","nombre":"Carta de antecedentes / buena conducta","obligatorio":false,"vence":false}]',
   'Documentos que se piden al registrar un conductor')
on conflict (clave) do nothing;

-- ---------- 4. Storage: bucket privado "documentos" ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 10485760,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

-- Cada conductor sube a la carpeta con su propio uid: documentos/<uid>/<archivo>
drop policy if exists "docs_subir_propio"  on storage.objects;
drop policy if exists "docs_ver_propio"    on storage.objects;
drop policy if exists "docs_borrar_propio" on storage.objects;
drop policy if exists "docs_admin"         on storage.objects;
create policy "docs_subir_propio" on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "docs_ver_propio" on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "docs_borrar_propio" on storage.objects for delete to authenticated
  using (bucket_id = 'documentos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "docs_admin" on storage.objects for all to authenticated
  using (bucket_id = 'documentos' and es_admin()) with check (bucket_id = 'documentos' and es_admin());

-- ---------- 5. RLS de documentos ----------
alter table documentos_conductor enable row level security;
drop policy if exists "docs_conductor_propio" on documentos_conductor;
drop policy if exists "docs_conductor_insert" on documentos_conductor;
drop policy if exists "docs_conductor_delete" on documentos_conductor;
drop policy if exists "docs_conductor_admin"  on documentos_conductor;
create policy "docs_conductor_propio" on documentos_conductor for select
  using (conductor_id = conductor_actual_id() or es_admin());
create policy "docs_conductor_insert" on documentos_conductor for insert
  with check (conductor_id = conductor_actual_id());
create policy "docs_conductor_delete" on documentos_conductor for delete
  using (conductor_id = conductor_actual_id() and estado in ('pendiente','rechazado','vencido'));
create policy "docs_conductor_admin" on documentos_conductor for all
  using (es_admin()) with check (es_admin());

-- El conductor puede ver y editar su propio vehículo (mientras no esté aprobado, solo datos básicos)
drop policy if exists "vehiculo_de_mi_conductor" on vehiculos;
drop policy if exists "vehiculo_insert_conductor" on vehiculos;
drop policy if exists "vehiculo_update_conductor" on vehiculos;
create policy "vehiculo_de_mi_conductor" on vehiculos for select using (conductor_id = conductor_actual_id());
create policy "vehiculo_insert_conductor" on vehiculos for insert with check (conductor_id = conductor_actual_id());
create policy "vehiculo_update_conductor" on vehiculos for update using (conductor_id = conductor_actual_id())
  with check (conductor_id = conductor_actual_id());

-- ---------- 6. RPC: registrar_conductor (autoservicio) ----------
-- Uso desde la app del conductor:
-- supabase.rpc('registrar_conductor', { p_datos: {...}, p_vehiculo: {...} })
-- p_datos:    {nombre, telefono, cedula, email, fecha_nacimiento, direccion, ciudad_base_id,
--              anios_experiencia, licencia, licencia_grado, licencia_vence}
-- p_vehiculo: {tipo_vehiculo_id, marca, modelo, anio, color, placa, capacidad_pasajeros,
--              aire_acondicionado, condicion, kilometraje, rcv_vence, notas}
create or replace function registrar_conductor(p_datos jsonb, p_vehiculo jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_c conductores%rowtype; v_v vehiculos%rowtype; v_rol rol_usuario;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select rol into v_rol from perfiles where id = auth.uid();
  if v_rol = 'admin' then raise exception 'Un administrador no puede registrarse como conductor'; end if;
  if coalesce(p_datos->>'nombre','') = '' or coalesce(p_datos->>'telefono','') = '' or coalesce(p_datos->>'cedula','') = '' then
    raise exception 'Nombre, teléfono y cédula son obligatorios';
  end if;
  if coalesce(p_vehiculo->>'placa','') = '' or coalesce(p_vehiculo->>'marca','') = '' or coalesce(p_vehiculo->>'modelo','') = '' then
    raise exception 'Marca, modelo y placa del vehículo son obligatorios';
  end if;

  -- crear o actualizar la ficha del conductor
  select * into v_c from conductores where perfil_id = auth.uid();
  if found then
    if v_c.estado = 'aprobado' then raise exception 'Ya eres conductor aprobado; edita tus datos desde el perfil'; end if;
    update conductores set
      nombre = p_datos->>'nombre', telefono = p_datos->>'telefono', cedula = p_datos->>'cedula',
      email = p_datos->>'email', fecha_nacimiento = (p_datos->>'fecha_nacimiento')::date,
      direccion = p_datos->>'direccion', ciudad_base_id = (p_datos->>'ciudad_base_id')::int,
      anios_experiencia = (p_datos->>'anios_experiencia')::int, licencia = p_datos->>'licencia',
      licencia_grado = p_datos->>'licencia_grado', licencia_vence = (p_datos->>'licencia_vence')::date,
      estado = 'pendiente', observacion_admin = null
    where id = v_c.id returning * into v_c;
  else
    insert into conductores (perfil_id, nombre, telefono, cedula, email, fecha_nacimiento, direccion, ciudad_base_id,
                             anios_experiencia, licencia, licencia_grado, licencia_vence, estado, activo)
    values (auth.uid(), p_datos->>'nombre', p_datos->>'telefono', p_datos->>'cedula', p_datos->>'email',
            (p_datos->>'fecha_nacimiento')::date, p_datos->>'direccion', (p_datos->>'ciudad_base_id')::int,
            (p_datos->>'anios_experiencia')::int, p_datos->>'licencia', p_datos->>'licencia_grado',
            (p_datos->>'licencia_vence')::date, 'pendiente', false)
    returning * into v_c;
  end if;

  -- vehículo (uno por conductor en el MVP; se identifica por placa)
  select * into v_v from vehiculos where conductor_id = v_c.id limit 1;
  if found then
    update vehiculos set
      tipo_vehiculo_id = (p_vehiculo->>'tipo_vehiculo_id')::int, marca = p_vehiculo->>'marca', modelo = p_vehiculo->>'modelo',
      anio = (p_vehiculo->>'anio')::int, color = p_vehiculo->>'color', placa = upper(p_vehiculo->>'placa'),
      capacidad_pasajeros = (p_vehiculo->>'capacidad_pasajeros')::int,
      aire_acondicionado = coalesce((p_vehiculo->>'aire_acondicionado')::boolean, true),
      condicion = p_vehiculo->>'condicion', kilometraje = (p_vehiculo->>'kilometraje')::int,
      rcv_vence = (p_vehiculo->>'rcv_vence')::date, notas = p_vehiculo->>'notas', activo = false
    where id = v_v.id returning * into v_v;
  else
    if exists (select 1 from vehiculos where placa = upper(p_vehiculo->>'placa')) then
      raise exception 'La placa % ya está registrada', upper(p_vehiculo->>'placa');
    end if;
    insert into vehiculos (tipo_vehiculo_id, conductor_id, marca, modelo, anio, color, placa, capacidad_pasajeros,
                           aire_acondicionado, condicion, kilometraje, rcv_vence, notas, activo)
    values ((p_vehiculo->>'tipo_vehiculo_id')::int, v_c.id, p_vehiculo->>'marca', p_vehiculo->>'modelo',
            (p_vehiculo->>'anio')::int, p_vehiculo->>'color', upper(p_vehiculo->>'placa'),
            (p_vehiculo->>'capacidad_pasajeros')::int, coalesce((p_vehiculo->>'aire_acondicionado')::boolean, true),
            p_vehiculo->>'condicion', (p_vehiculo->>'kilometraje')::int, (p_vehiculo->>'rcv_vence')::date,
            p_vehiculo->>'notas', false)
    returning * into v_v;
  end if;

  -- el perfil pasa a rol conductor (sigue sin poder tomar viajes hasta ser aprobado)
  update perfiles set rol = 'conductor', nombre = coalesce(nullif(nombre,''), p_datos->>'nombre'),
                      telefono = coalesce(nullif(telefono,''), p_datos->>'telefono'), cedula = p_datos->>'cedula'
   where id = auth.uid() and rol <> 'admin';

  return jsonb_build_object('conductor', to_jsonb(v_c), 'vehiculo', to_jsonb(v_v));
end $$;

-- ---------- 7. RPC: mi_ficha_conductor (la app la llama al entrar) ----------
create or replace function mi_ficha_conductor()
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'conductor', to_jsonb(c),
    'vehiculo', (select to_jsonb(v) from vehiculos v where v.conductor_id = c.id limit 1),
    'documentos', (select coalesce(jsonb_agg(to_jsonb(d) order by d.subido_en desc), '[]'::jsonb) from documentos_conductor d where d.conductor_id = c.id),
    'requisitos', (select valor from configuracion where clave = 'publico.documentos_conductor')
  )
  from conductores c where c.perfil_id = auth.uid();
$$;

-- ---------- 8. RPC: registrar_documento (tras subir el archivo al bucket) ----------
create or replace function registrar_documento(p_tipo tipo_documento, p_archivo_path text, p_nombre_archivo text, p_vence_el date default null)
returns documentos_conductor
language plpgsql security definer set search_path = public as $$
declare v_cid uuid; v_doc documentos_conductor%rowtype;
begin
  select id into v_cid from conductores where perfil_id = auth.uid();
  if v_cid is null then raise exception 'Primero completa tu registro de conductor'; end if;
  if split_part(p_archivo_path, '/', 1) <> auth.uid()::text then raise exception 'Ruta de archivo inválida'; end if;
  -- reemplaza el documento anterior del mismo tipo (queda solo el más reciente)
  delete from documentos_conductor where conductor_id = v_cid and tipo = p_tipo and estado <> 'aprobado';
  insert into documentos_conductor (conductor_id, tipo, archivo_path, nombre_archivo, vence_el)
  values (v_cid, p_tipo, p_archivo_path, p_nombre_archivo, p_vence_el) returning * into v_doc;
  -- si el conductor estaba rechazado, vuelve a revisión
  update conductores set estado = 'pendiente' where id = v_cid and estado = 'rechazado';
  return v_doc;
end $$;

-- ---------- 9. RPC admin: revisar_conductor / revisar_documento ----------
create or replace function revisar_conductor(p_conductor_id uuid, p_estado estado_conductor, p_observacion text default null)
returns conductores
language plpgsql security definer set search_path = public as $$
declare v_c conductores%rowtype;
begin
  if not es_admin() then raise exception 'Solo administradores'; end if;
  update conductores set estado = p_estado, observacion_admin = p_observacion,
                         revisado_por = auth.uid(), revisado_en = now(),
                         activo = (p_estado = 'aprobado')
   where id = p_conductor_id returning * into v_c;
  if not found then raise exception 'Conductor no encontrado'; end if;
  update vehiculos set activo = (p_estado = 'aprobado') where conductor_id = p_conductor_id;
  return v_c;
end $$;

create or replace function revisar_documento(p_documento_id uuid, p_estado estado_documento, p_observacion text default null)
returns documentos_conductor
language plpgsql security definer set search_path = public as $$
declare v_d documentos_conductor%rowtype;
begin
  if not es_admin() then raise exception 'Solo administradores'; end if;
  update documentos_conductor set estado = p_estado, observacion = p_observacion,
                                  revisado_por = auth.uid(), revisado_en = now()
   where id = p_documento_id returning * into v_d;
  if not found then raise exception 'Documento no encontrado'; end if;
  return v_d;
end $$;

-- ---------- 10. Vista admin: solicitudes de conductores ----------
create or replace view v_conductores_admin
with (security_invoker = true) as
select c.id, c.estado, c.nombre, c.telefono, c.cedula, c.email, c.licencia_grado, c.licencia_vence,
       c.anios_experiencia, c.calificacion, c.total_viajes, c.observacion_admin, c.creado_en,
       ci.nombre as ciudad_base,
       v.marca || ' ' || v.modelo || ' ' || coalesce(v.anio::text,'') as vehiculo, v.placa, v.condicion, v.rcv_vence,
       tv.nombre as tipo_vehiculo,
       (select count(*) from documentos_conductor d where d.conductor_id = c.id) as documentos,
       (select count(*) from documentos_conductor d where d.conductor_id = c.id and d.estado = 'aprobado') as documentos_aprobados,
       (select count(*) from documentos_conductor d where d.conductor_id = c.id and d.estado = 'pendiente') as documentos_pendientes
from conductores c
left join ciudades ci on ci.id = c.ciudad_base_id
left join vehiculos v on v.conductor_id = c.id
left join tipos_vehiculo tv on tv.id = v.tipo_vehiculo_id;
grant select on v_conductores_admin to authenticated;

-- ---------- 11. asignar_conductor: exigir conductor aprobado ----------
create or replace function asignar_conductor(p_reserva_id uuid, p_conductor_id uuid, p_vehiculo_id uuid)
returns reservas
language plpgsql security definer set search_path = public as $$
declare v_res reservas%rowtype; v_veh vehiculos%rowtype; v_con conductores%rowtype;
begin
  if not es_admin() then raise exception 'Solo administradores'; end if;
  select * into v_res from reservas where id = p_reserva_id;
  if not found then raise exception 'Reserva no encontrada'; end if;
  if v_res.estado not in ('confirmada','asignada') then raise exception 'La reserva debe estar confirmada para asignar'; end if;
  select * into v_con from conductores where id = p_conductor_id and activo and estado = 'aprobado';
  if not found then raise exception 'El conductor no está aprobado o está inactivo'; end if;
  select * into v_veh from vehiculos where id = p_vehiculo_id and activo;
  if not found then raise exception 'Vehículo no disponible'; end if;
  if v_veh.tipo_vehiculo_id <> v_res.tipo_vehiculo_id then raise exception 'El vehículo no es del tipo reservado'; end if;
  if v_veh.capacidad_pasajeros < v_res.pasajeros then raise exception 'El vehículo no tiene capacidad suficiente'; end if;
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

-- ---------- 12. Viajes del conductor (lista para su app) ----------
create or replace function mis_viajes_conductor()
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id, 'codigo', r.codigo, 'estado', r.estado, 'fecha_viaje', r.fecha_viaje, 'hora_viaje', r.hora_viaje,
    'pasajeros', r.pasajeros, 'equipaje', r.equipaje, 'precio_total', r.precio_total,
    'origen', co.nombre, 'destino', cd.nombre,
    'direccion_recogida', r.direccion_recogida, 'direccion_destino', r.direccion_destino, 'notas', r.notas,
    'cliente', jsonb_build_object('nombre', p.nombre || ' ' || coalesce(p.apellido,''), 'telefono', p.telefono),
    'lista_pasajeros', (select coalesce(jsonb_agg(jsonb_build_object('nombre', x.nombre, 'cedula', x.cedula)), '[]'::jsonb) from pasajeros x where x.reserva_id = r.id),
    'metodo_pago', (select pg.metodo from pagos pg where pg.reserva_id = r.id order by pg.creado_en desc limit 1)
  ) order by r.fecha_viaje, r.hora_viaje), '[]'::jsonb)
  from reservas r
  join rutas ru on ru.id = r.ruta_id
  join ciudades co on co.id = ru.origen_id
  join ciudades cd on cd.id = ru.destino_id
  join perfiles p on p.id = r.cliente_id
  where r.conductor_id = conductor_actual_id();
$$;

grant execute on all functions in schema public to authenticated;
revoke execute on function revisar_conductor(uuid,estado_conductor,text), revisar_documento(uuid,estado_documento,text) from anon;
