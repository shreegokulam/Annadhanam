-- ============================================================
-- Lunch Queue — Supabase setup. Run ONCE in Supabase > SQL Editor.
-- Tables are locked (RLS, no policies); everything goes through
-- the functions below. Staff/admin functions need a PIN.
-- ============================================================
create extension if not exists pgcrypto;

create table if not exists settings (key text primary key, value text not null);
insert into settings(key,value) values
 ('event_title','Annadhanam (Lunch Prasadam)'),
 ('event_date','2026-12-20'),
 ('slot_cap','250'),
 ('max_per_phone','2'),
 ('booking_open','true'),
 ('staff_pin','123456'),   -- CHANGE in Admin > Settings
 ('admin_pin','654321')    -- CHANGE in Admin > Settings
on conflict (key) do nothing;

create table if not exists bookings (
 id bigserial primary key,
 code text unique not null,
 name text not null,
 phone text not null,
 phone_key text not null,
 slot text not null,
 party_size int not null check (party_size between 1 and 4),
 checked_in int not null default 0,
 checked_in_at timestamptz,
 walk_in boolean not null default false,
 cancelled boolean not null default false,
 created_at timestamptz not null default now()
);
create index if not exists bookings_phone_idx on bookings(phone_key);
create index if not exists bookings_slot_idx on bookings(slot);

alter table settings enable row level security;
alter table bookings enable row level security;

-- ---------- internal helpers (not callable from the web) ----------
create or replace function _s(k text) returns text
language sql stable security definer set search_path=public as
$$ select value from settings where key=k $$;

create or replace function _slots() returns text[]
language sql immutable as
$$ select array['12:00','12:30','13:00','13:30','14:00','14:30'] $$;

create or replace function _need_staff(p text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if p is distinct from _s('staff_pin') and p is distinct from _s('admin_pin') then
    raise exception 'bad_pin';
  end if;
end $$;

create or replace function _need_admin(p text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if p is distinct from _s('admin_pin') then raise exception 'bad_pin'; end if;
end $$;

create or replace function _new_code() returns text
language plpgsql security definer set search_path=public,extensions as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; c text; i int; bytes bytea;
begin
  loop
    bytes := gen_random_bytes(8); c := '';
    for i in 0..7 loop
      c := c || substr(a, 1 + (get_byte(bytes,i) % length(a)), 1);
    end loop;
    exit when not exists (select 1 from bookings where code = c);
  end loop;
  return c;
end $$;

create or replace function _row(b bookings) returns json
language sql immutable as $$
  select json_build_object('code',b.code,'name',b.name,'phone',b.phone,'slot',b.slot,
    'party_size',b.party_size,'checked_in',b.checked_in,'checked_in_at',b.checked_in_at,
    'cancelled',b.cancelled,'walk_in',b.walk_in)
$$;

create or replace function _book(p_name text,p_phone text,p_slot text,p_size int,p_walk boolean)
returns json language plpgsql security definer set search_path=public,extensions as $$
declare
  cap int := _s('slot_cap')::int;
  maxp int := _s('max_per_phone')::int;
  pk text; used int; mine int; b bookings;
begin
  p_name := btrim(coalesce(p_name,''));
  if length(p_name) < 2 then raise exception 'name_required'; end if;
  -- guest bookings: UAE mobile only, 10 digits starting with 05, numbers only
  if not p_walk and coalesce(p_phone,'') !~ '^05[0-9]{8}$' then raise exception 'phone_invalid'; end if;
  pk := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),9);
  if length(pk) < 7 then
    if p_walk then pk := 'walkin'; else raise exception 'phone_invalid'; end if;
  end if;
  if not (p_slot = any(_slots())) then raise exception 'slot_invalid'; end if;
  if p_size is null or p_size < 1 or p_size > 4 then raise exception 'size_invalid'; end if;

  -- serialise bookings per slot so two people can never take the last seat
  perform pg_advisory_xact_lock(hashtext('slot'||p_slot));
  select coalesce(sum(party_size),0) into used from bookings where slot=p_slot and not cancelled;
  if used + p_size > cap then raise exception 'slot_full'; end if;

  if not p_walk then
    select count(*) into mine from bookings where phone_key=pk and not cancelled and not walk_in;
    if mine >= maxp then raise exception 'phone_limit'; end if;
  end if;

  insert into bookings(code,name,phone,phone_key,slot,party_size,walk_in,checked_in,checked_in_at)
  values(_new_code(), left(p_name,60), left(coalesce(nullif(p_phone,''),'-'),20), pk, p_slot, p_size, p_walk,
         case when p_walk then p_size else 0 end,
         case when p_walk then now() end)
  returning * into b;
  return _row(b);
end $$;

-- ---------- public functions (guests) ----------
create or replace function get_public_info() returns json
language sql stable security definer set search_path=public as $$
  select json_build_object(
    'title',_s('event_title'),
    'date',_s('event_date'),
    'open',_s('booking_open')='true',
    'cap',_s('slot_cap')::int,
    'slots',(select json_agg(json_build_object('slot',s,
        'booked',coalesce((select sum(party_size) from bookings where slot=s and not cancelled),0)) order by s)
      from unnest(_slots()) s))
$$;

create or replace function book(p_name text,p_phone text,p_slot text,p_size int) returns json
language plpgsql security definer set search_path=public,extensions as $$
begin
  if _s('booking_open') <> 'true' then raise exception 'closed'; end if;
  return _book(p_name,p_phone,p_slot,p_size,false);
end $$;

create or replace function get_ticket(p_code text) returns json
language plpgsql stable security definer set search_path=public as $$
declare b bookings;
begin
  select * into b from bookings where code = upper(btrim(p_code));
  if not found then return null; end if;
  return _row(b);
end $$;

create or replace function find_bookings(p_name text,p_phone text) returns json
language plpgsql stable security definer set search_path=public as $$
declare
  pk text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),9);
  nm text := lower(btrim(coalesce(p_name,'')));
begin
  if length(pk) < 7 or length(nm) < 2 then return '[]'::json; end if;
  return coalesce((select json_agg(_row(b) order by b.created_at) from bookings b
     where b.phone_key = pk and not b.cancelled and lower(b.name) like '%'||nm||'%'),'[]'::json);
end $$;

-- ---------- staff functions (scanner volunteers; need staff or admin PIN) ----------
create or replace function staff_list(p_pin text) returns json
language plpgsql stable security definer set search_path=public as $$
begin
  perform _need_staff(p_pin);
  return coalesce((select json_agg(json_build_object('code',code,'name',name,'phone',phone,'slot',slot,
    'party_size',party_size,'checked_in',checked_in,'checked_in_at',checked_in_at,
    'cancelled',cancelled,'walk_in',walk_in,'created_at',created_at) order by created_at desc) from bookings),'[]'::json);
end $$;

create or replace function staff_search(p_pin text,p_q text) returns json
language plpgsql stable security definer set search_path=public as $$
declare q text := btrim(coalesce(p_q,'')); d text := regexp_replace(btrim(coalesce(p_q,'')),'\D','','g');
begin
  perform _need_staff(p_pin);
  return coalesce((select json_agg(_row(b) order by b.created_at) from bookings b where b.id in (
    select id from bookings x where not x.cancelled and (
         x.code = upper(q)
      or (length(d) >= 4 and length(d) = length(regexp_replace(q,'[\s+\-()]','','g')) and x.phone_key like '%'||d||'%')
      or (length(q) >= 2 and x.name ilike '%'||q||'%'))
    limit 20)),'[]'::json);
end $$;

create or replace function staff_check_in(p_pin text,p_code text) returns json
language plpgsql security definer set search_path=public as $$
declare b bookings; prev int;
begin
  perform _need_staff(p_pin);
  select * into b from bookings where code = upper(btrim(p_code)) for update;
  if not found then return json_build_object('status','not_found'); end if;
  if b.cancelled then return json_build_object('status','cancelled','booking',_row(b)); end if;
  if b.checked_in >= b.party_size then return json_build_object('status','already','booking',_row(b)); end if;
  prev := b.checked_in;
  update bookings set checked_in = party_size, checked_in_at = now() where id = b.id returning * into b;
  return json_build_object('status','ok','previous',prev,'booking',_row(b));
end $$;

create or replace function staff_set_checked_in(p_pin text,p_code text,p_n int) returns json
language plpgsql security definer set search_path=public as $$
declare b bookings;
begin
  perform _need_staff(p_pin);
  update bookings set checked_in = least(greatest(p_n,0),party_size),
                      checked_in_at = case when p_n > 0 then now() else null end
   where code = upper(btrim(p_code)) returning * into b;
  if not found then raise exception 'not_found'; end if;
  return _row(b);
end $$;

create or replace function staff_walkin(p_pin text,p_name text,p_phone text,p_slot text,p_size int) returns json
language plpgsql security definer set search_path=public,extensions as $$
begin
  perform _need_staff(p_pin);
  return _book(coalesce(nullif(btrim(p_name),''),'Walk-in'),p_phone,p_slot,p_size,true);
end $$;

-- ---------- admin functions (admin PIN) ----------
create or replace function admin_get_settings(p_pin text) returns json
language plpgsql stable security definer set search_path=public as $$
begin
  perform _need_admin(p_pin);
  return (select json_object_agg(key,value) from settings);
end $$;

create or replace function admin_set_settings(p_pin text,p_settings json) returns json
language plpgsql security definer set search_path=public as $$
declare k text; v text;
begin
  perform _need_admin(p_pin);
  for k, v in select key, value from json_each_text(p_settings) loop
    if k not in ('event_title','event_date','slot_cap','max_per_phone','booking_open','staff_pin','admin_pin') then continue; end if;
    if k in ('slot_cap','max_per_phone') and (v !~ '^\d{1,4}$' or v::int < 1) then raise exception 'invalid_%', k; end if;
    if k in ('staff_pin','admin_pin') and length(v) < 4 then raise exception 'pin_short'; end if;
    update settings set value = v where key = k;
  end loop;
  return admin_get_settings(_s('admin_pin'));
end $$;

create or replace function admin_cancel(p_pin text,p_code text,p_cancel boolean) returns json
language plpgsql security definer set search_path=public as $$
declare b bookings;
begin
  perform _need_admin(p_pin);
  update bookings set cancelled = p_cancel where code = upper(btrim(p_code)) returning * into b;
  if not found then raise exception 'not_found'; end if;
  return _row(b);
end $$;

-- ---------- permissions ----------
revoke all on function _s(text), _need_staff(text), _need_admin(text), _new_code(),
  _row(bookings), _book(text,text,text,int,boolean) from public, anon, authenticated;

grant execute on function
  get_public_info(), book(text,text,text,int), get_ticket(text), find_bookings(text,text),
  staff_list(text), staff_search(text,text), staff_check_in(text,text),
  staff_set_checked_in(text,text,int), staff_walkin(text,text,text,text,int),
  admin_get_settings(text), admin_set_settings(text,json), admin_cancel(text,text,boolean)
to anon, authenticated;
