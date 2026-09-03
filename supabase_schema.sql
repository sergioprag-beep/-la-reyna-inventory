-- LA REYNA XPRESS INVENTORY CLOUD
-- Esquema inicial para una base de datos multi-dispositivo.
-- Ejecutar en el SQL Editor del proyecto Supabase.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'inventory',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text,
  supplier_id uuid,
  sku text,
  barcode text,
  packaging text,
  qty_per_package numeric,
  unit text,
  cost numeric not null default 0,
  stock numeric not null default 0,
  minimum_stock numeric not null default 0,
  emergency_stock numeric not null default 0,
  photo_url text,
  location text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  email text,
  terms text,
  created_at timestamptz not null default now()
);

create table if not exists public.movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete cascade,
  movement_type text not null,
  quantity numeric not null,
  unit_cost numeric default 0,
  note text,
  location text,
  user_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid references public.suppliers(id),
  status text not null default 'draft',
  invoice_number text,
  total numeric not null default 0,
  due_date date,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.recipes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text,
  yield_qty numeric,
  sale_price numeric default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.recipe_ingredients (
  id uuid primary key default gen_random_uuid(),
  recipe_id uuid references public.recipes(id) on delete cascade,
  product_id uuid references public.products(id) on delete cascade,
  quantity numeric not null,
  unit text
);

create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id),
  action text not null,
  detail text,
  created_at timestamptz not null default now()
);

create index if not exists products_sku_idx on public.products(sku);
create index if not exists products_barcode_idx on public.products(barcode);
create index if not exists movements_product_idx on public.movements(product_id);
create index if not exists movements_created_idx on public.movements(created_at);
