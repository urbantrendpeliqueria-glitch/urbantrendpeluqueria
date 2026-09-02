-- Urban Trend · agenda real, bloqueos y sobreturnos
-- Ejecutar una sola vez en Supabase > SQL Editor.

create extension if not exists pgcrypto;

alter table public.services
  add column if not exists duration_minutes integer,
  add column if not exists active_minutes integer,
  add column if not exists wait_minutes integer not null default 0,
  add column if not exists cycles integer not null default 1,
  add column if not exists final_active_minutes integer not null default 0,
  add column if not exists buffer_minutes integer not null default 0,
  add column if not exists allows_overbooking boolean not null default false;

update public.services set
  duration_minutes=coalesce(duration_minutes,case when lower(duration) like '%hora%' then nullif(substring(duration from '[0-9]+'),'')::integer*60 else nullif(substring(duration from '[0-9]+'),'')::integer end,30),
  active_minutes=coalesce(active_minutes,duration_minutes,case when lower(duration) like '%hora%' then nullif(substring(duration from '[0-9]+'),'')::integer*60 else nullif(substring(duration from '[0-9]+'),'')::integer end,30)
where duration_minutes is null or active_minutes is null;

alter table public.business_settings add column if not exists schedule_ready boolean not null default false;

create table if not exists public.business_hours (
  day_of_week smallint primary key check(day_of_week between 0 and 6),
  enabled boolean not null default false,
  opens_at time not null default '09:00',
  closes_at time not null default '20:00',
  updated_at timestamptz not null default now(),
  check(closes_at>opens_at)
);

insert into public.business_hours(day_of_week,enabled,opens_at,closes_at)
select d, d between 1 and 6, '09:00', '20:00' from generate_series(0,6) d
on conflict(day_of_week) do nothing;

create table if not exists public.schedule_blocks (
  id uuid primary key default gen_random_uuid(),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text not null default '',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check(ends_at>starts_at)
);

alter table public.bookings
  add column if not exists service_id text references public.services(id) on update cascade on delete set null,
  add column if not exists starts_at timestamptz,
  add column if not exists ends_at timestamptz,
  add column if not exists duration_minutes integer,
  add column if not exists active_minutes integer,
  add column if not exists wait_minutes integer not null default 0,
  add column if not exists cycles integer not null default 1,
  add column if not exists final_active_minutes integer not null default 0,
  add column if not exists buffer_minutes integer not null default 0,
  add column if not exists allows_overbooking boolean not null default false;

update public.bookings b set service_id=s.id,starts_at=(b.booking_date+b.booking_time) at time zone 'America/Argentina/Buenos_Aires',ends_at=((b.booking_date+b.booking_time) at time zone 'America/Argentina/Buenos_Aires')+make_interval(mins=>coalesce(s.duration_minutes,30)),duration_minutes=coalesce(s.duration_minutes,30),active_minutes=coalesce(s.active_minutes,s.duration_minutes,30),wait_minutes=coalesce(s.wait_minutes,0),cycles=coalesce(s.cycles,1),final_active_minutes=coalesce(s.final_active_minutes,0),buffer_minutes=coalesce(s.buffer_minutes,0),allows_overbooking=coalesce(s.allows_overbooking,false)
from public.services s where b.service_id is null and lower(trim(b.service_name))=lower(trim(s.name));

create index if not exists bookings_starts_at_idx on public.bookings(starts_at);
create index if not exists schedule_blocks_starts_at_idx on public.schedule_blocks(starts_at);

alter table public.business_hours enable row level security;
alter table public.schedule_blocks enable row level security;
grant select on public.business_hours to anon,authenticated;
grant select,insert,update,delete on public.business_hours,public.schedule_blocks to authenticated;
revoke all on public.schedule_blocks from anon;

drop policy if exists "Public reads hours" on public.business_hours;
create policy "Public reads hours" on public.business_hours for select using(true);
drop policy if exists "Admin manages hours" on public.business_hours;
create policy "Admin manages hours" on public.business_hours for all to authenticated
using(public.is_urban_admin()) with check(public.is_urban_admin());
drop policy if exists "Admin manages blocks" on public.schedule_blocks;
create policy "Admin manages blocks" on public.schedule_blocks for all to authenticated
using(public.is_urban_admin()) with check(public.is_urban_admin());

create or replace function public.service_segments(
  p_start timestamptz,p_duration integer,p_active integer,p_wait integer,
  p_cycles integer,p_final integer,p_buffer integer,p_overbooking boolean
) returns table(segment_start timestamptz,segment_end timestamptz)
language plpgsql immutable as $$
declare i integer; v_cursor timestamptz; v_finish timestamptz; v_end timestamptz;
begin
  v_finish:=p_start+make_interval(mins=>greatest(coalesce(p_duration,30),1));
  if not coalesce(p_overbooking,false) or coalesce(p_wait,0)<=0 then
    return query select p_start,v_finish+make_interval(mins=>greatest(coalesce(p_buffer,0),0)); return;
  end if;
  v_cursor:=p_start;
  for i in 1..greatest(coalesce(p_cycles,1),1) loop
    exit when v_cursor>=v_finish;
    v_end:=least(v_cursor+make_interval(mins=>greatest(coalesce(p_active,20),1)),v_finish);
    return query select v_cursor,v_end;
    v_cursor:=v_cursor+make_interval(mins=>greatest(coalesce(p_active,20),1)+greatest(coalesce(p_wait,0),0));
  end loop;
  if coalesce(p_final,0)>0 and v_cursor<v_finish then
    return query select v_cursor,least(v_cursor+make_interval(mins=>p_final),v_finish);
  end if;
  if coalesce(p_buffer,0)>0 then return query select v_finish,v_finish+make_interval(mins=>p_buffer); end if;
end $$;

create or replace function public.slot_problem(p_date date,p_time time,p_service_id text,p_ignore_booking text default null)
returns text language plpgsql security definer set search_path=public as $$
declare v_s public.services%rowtype; v_h public.business_hours%rowtype; v_start timestamptz; v_end timestamptz; v_ready boolean;
begin
  select * into v_s from public.services where id=p_service_id and active=true;
  if not found then return 'Servicio inválido'; end if;
  select schedule_ready into v_ready from public.business_settings where id='main';
  if not coalesce(v_ready,false) then return 'El negocio todavía debe configurar sus horarios'; end if;
  select * into v_h from public.business_hours where day_of_week=extract(dow from p_date)::integer;
  if not found or not v_h.enabled then return 'El local no atiende ese día'; end if;
  v_start:=(p_date+p_time) at time zone 'America/Argentina/Buenos_Aires';
  v_end:=v_start+make_interval(mins=>greatest(coalesce(v_s.duration_minutes,30),1));
  if v_start<=now() then return 'Ese horario ya pasó'; end if;
  if p_time<v_h.opens_at or v_end>((p_date+v_h.closes_at) at time zone 'America/Argentina/Buenos_Aires')
    then return 'El servicio no entra completo en el horario de atención'; end if;
  if exists(select 1 from public.schedule_blocks x where tstzrange(x.starts_at,x.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then return 'Ese horario está bloqueado'; end if;
  if exists(
    select 1 from public.service_segments(v_start,v_s.duration_minutes,v_s.active_minutes,v_s.wait_minutes,v_s.cycles,v_s.final_active_minutes,v_s.buffer_minutes,v_s.allows_overbooking) n
    join public.bookings b on b.status in ('Pendiente','Confirmado') and b.starts_at is not null and b.id is distinct from p_ignore_booking
    cross join lateral public.service_segments(b.starts_at,b.duration_minutes,b.active_minutes,b.wait_minutes,b.cycles,b.final_active_minutes,b.buffer_minutes,b.allows_overbooking) e
    where tstzrange(n.segment_start,n.segment_end,'[)')&&tstzrange(e.segment_start,e.segment_end,'[)')
  ) then return 'Ese tramo de trabajo ya está ocupado'; end if;
  return null;
end $$;

create or replace function public.available_slots(p_date date,p_service_id text)
returns table(slot_time time) language plpgsql security definer set search_path=public as $$
declare v_h public.business_hours%rowtype; v_t time;
begin
  select * into v_h from public.business_hours where day_of_week=extract(dow from p_date)::integer;
  if not found or not v_h.enabled then return; end if;
  v_t:=v_h.opens_at;
  while v_t<v_h.closes_at loop
    if public.slot_problem(p_date,v_t,p_service_id) is null then slot_time:=v_t; return next; end if;
    v_t:=v_t+interval '20 minutes';
  end loop;
end $$;
revoke all on function public.available_slots(date,text) from public;
grant execute on function public.available_slots(date,text) to anon,authenticated;

create or replace function public.request_booking_v2(
  p_id text,p_display_name text,p_phone text,p_service_id text,p_booking_date date,p_booking_time time,p_notes text,p_terms_accepted_at timestamptz
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_contact uuid;v_profile uuid;v_service public.services%rowtype;v_check jsonb;v_problem text;v_start timestamptz;
begin
  if p_terms_accepted_at is null then raise exception 'Debe aceptar los términos'; end if;
  if length(public.normalize_phone(p_phone))<8 then raise exception 'Teléfono inválido'; end if;
  select * into v_service from public.services where id=p_service_id and active=true;
  if not found then raise exception 'Servicio inválido'; end if;
  perform pg_advisory_xact_lock(hashtext(p_booking_date::text));
  v_problem:=public.slot_problem(p_booking_date,p_booking_time,p_service_id);
  if v_problem is not null then return jsonb_build_object('ok',false,'code','SLOT_UNAVAILABLE','message',v_problem); end if;
  v_check:=public.safety_result(p_phone,p_display_name,p_service_id);
  if coalesce((v_check->>'blocked')::boolean,false) then return v_check||jsonb_build_object('ok',false,'code','SAFETY_WAIT'); end if;
  insert into public.contacts(phone) values(trim(p_phone)) on conflict(phone_normalized) do update set phone=excluded.phone,updated_at=now() returning id into v_contact;
  insert into public.customer_profiles(contact_id,display_name) values(v_contact,trim(p_display_name)) on conflict(contact_id,name_key) do update set display_name=excluded.display_name,updated_at=now() returning id into v_profile;
  v_start:=(p_booking_date+p_booking_time) at time zone 'America/Argentina/Buenos_Aires';
  insert into public.bookings(id,customer_name,customer_surname,phone,service_name,service_id,booking_date,booking_time,starts_at,ends_at,notes,status,terms_accepted_at,contact_id,profile_id,safety_checked_at,duration_minutes,active_minutes,wait_minutes,cycles,final_active_minutes,buffer_minutes,allows_overbooking)
  values(p_id,trim(p_display_name),'',trim(p_phone),v_service.name,v_service.id,p_booking_date,p_booking_time,v_start,v_start+make_interval(mins=>coalesce(v_service.duration_minutes,30)),trim(coalesce(p_notes,'')),'Pendiente',p_terms_accepted_at,v_contact,v_profile,now(),v_service.duration_minutes,v_service.active_minutes,v_service.wait_minutes,v_service.cycles,v_service.final_active_minutes,v_service.buffer_minutes,v_service.allows_overbooking);
  return jsonb_build_object('ok',true,'booking_id',p_id);
end $$;

create or replace function public.admin_request_booking(
  p_id text,p_display_name text,p_phone text,p_service_id text,p_booking_date date,p_booking_time time,p_notes text,p_override_reason text default ''
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_contact uuid;v_profile uuid;v_service public.services%rowtype;v_check jsonb;v_problem text;v_blocked boolean;v_override boolean;v_start timestamptz;
begin
  if not public.is_urban_admin() then raise exception 'Acceso no autorizado'; end if;
  select * into v_service from public.services where id=p_service_id and active=true;
  if not found then raise exception 'Servicio inválido'; end if;
  perform pg_advisory_xact_lock(hashtext(p_booking_date::text));
  v_problem:=public.slot_problem(p_booking_date,p_booking_time,p_service_id);
  v_check:=public.safety_result(p_phone,p_display_name,p_service_id);
  v_blocked:=coalesce((v_check->>'blocked')::boolean,false);v_override:=v_blocked or v_problem is not null;
  if v_override and length(trim(coalesce(p_override_reason,'')))<5 then return coalesce(v_check,'{}'::jsonb)||jsonb_build_object('ok',false,'code','OVERRIDE_REASON_REQUIRED','message',coalesce(v_problem,v_check->>'message','Se requiere justificar la excepción')); end if;
  insert into public.contacts(phone) values(trim(p_phone)) on conflict(phone_normalized) do update set phone=excluded.phone,updated_at=now() returning id into v_contact;
  insert into public.customer_profiles(contact_id,display_name) values(v_contact,trim(p_display_name)) on conflict(contact_id,name_key) do update set display_name=excluded.display_name,updated_at=now() returning id into v_profile;
  v_start:=(p_booking_date+p_booking_time) at time zone 'America/Argentina/Buenos_Aires';
  insert into public.bookings(id,customer_name,customer_surname,phone,service_name,service_id,booking_date,booking_time,starts_at,ends_at,notes,status,terms_accepted_at,contact_id,profile_id,safety_checked_at,safety_override,safety_override_reason,safety_override_by,duration_minutes,active_minutes,wait_minutes,cycles,final_active_minutes,buffer_minutes,allows_overbooking)
  values(p_id,trim(p_display_name),'',trim(p_phone),v_service.name,v_service.id,p_booking_date,p_booking_time,v_start,v_start+make_interval(mins=>coalesce(v_service.duration_minutes,30)),trim(coalesce(p_notes,'')),'Pendiente',now(),v_contact,v_profile,now(),v_override,case when v_override then trim(p_override_reason) else '' end,case when v_override then auth.uid() else null end,v_service.duration_minutes,v_service.active_minutes,v_service.wait_minutes,v_service.cycles,v_service.final_active_minutes,v_service.buffer_minutes,v_service.allows_overbooking);
  return jsonb_build_object('ok',true,'booking_id',p_id,'safety_override',v_override);
end $$;

revoke all on function public.request_booking_v2(text,text,text,text,date,time,text,timestamptz) from public;
grant execute on function public.request_booking_v2(text,text,text,text,date,time,text,timestamptz) to anon,authenticated;
revoke all on function public.admin_request_booking(text,text,text,text,date,time,text,text) from public,anon;
grant execute on function public.admin_request_booking(text,text,text,text,date,time,text,text) to authenticated;

create or replace function public.save_business_hours(p_hours jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_urban_admin() then raise exception 'Acceso no autorizado'; end if;
  insert into public.business_hours(day_of_week,enabled,opens_at,closes_at,updated_at)
  select (x->>'day')::smallint,coalesce((x->>'enabled')::boolean,false),(x->>'opens')::time,(x->>'closes')::time,now() from jsonb_array_elements(p_hours)x
  on conflict(day_of_week) do update set enabled=excluded.enabled,opens_at=excluded.opens_at,closes_at=excluded.closes_at,updated_at=now();
  update public.business_settings set schedule_ready=true,updated_at=now() where id='main';
end $$;
revoke all on function public.save_business_hours(jsonb) from public,anon;
grant execute on function public.save_business_hours(jsonb) to authenticated;
