


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."claim_reason_enum" AS ENUM (
    'missing_item',
    'wrong_item',
    'production_failure',
    'other'
);


ALTER TYPE "public"."claim_reason_enum" OWNER TO "postgres";


CREATE TYPE "public"."order_claim_type_enum" AS ENUM (
    'refund',
    'replace'
);


ALTER TYPE "public"."order_claim_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."order_status_enum" AS ENUM (
    'pending',
    'completed',
    'draft',
    'archived',
    'canceled',
    'requires_action'
);


ALTER TYPE "public"."order_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."return_status_enum" AS ENUM (
    'open',
    'requested',
    'received',
    'partially_received',
    'canceled'
);


ALTER TYPE "public"."return_status_enum" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_deals_ean_blacklist"("p_ean" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if trim(coalesce(p_ean,'')) = '' then
    raise exception 'EAN is required';
  end if;

  insert into public.deals_ean_blacklist (ean, note)
  values (trim(p_ean), nullif(trim(coalesce(p_note,'')), ''))
  on conflict (ean)
  do update set
    note = coalesce(excluded.note, public.deals_ean_blacklist.note),
    created_at = now();
end;
$$;


ALTER FUNCTION "public"."add_deals_ean_blacklist"("p_ean" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_deals_ean_blacklist_bulk"("p_eans" "text"[], "p_note" "text" DEFAULT NULL::"text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_count integer;
begin
  if p_eans is null or array_length(p_eans, 1) is null then
    return 0;
  end if;

  with cleaned as (
    select distinct nullif(btrim(ean), '') as ean
    from unnest(p_eans) as t(ean)
  ), ins as (
    insert into public.deals_ean_blacklist (ean, note)
    select c.ean, p_note
    from cleaned c
    where c.ean is not null
    on conflict (ean) do update
      set note = coalesce(excluded.note, public.deals_ean_blacklist.note)
    returning 1
  )
  select count(*) into v_count from ins;

  return v_count;
end;
$$;


ALTER FUNCTION "public"."add_deals_ean_blacklist_bulk"("p_eans" "text"[], "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_deals_ean_blacklist_from_search"("p_search" "text", "p_min_savings" numeric DEFAULT 0, "p_min_sources" integer DEFAULT 1, "p_price_min" numeric DEFAULT NULL::numeric, "p_price_max" numeric DEFAULT NULL::numeric, "p_scrapers" "text"[] DEFAULT NULL::"text"[], "p_note" "text" DEFAULT NULL::"text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_inserted integer := 0;
  v_search text := trim(coalesce(p_search, ''));
  v_like text;
  v_scrapers text[];
begin
  if v_search = '' then
    return 0;
  end if;

  v_like := '%' || public.normalize_search_de(v_search) || '%';

  if p_scrapers is null then
    select coalesce(array(
      select src from (
        select s.source as src from public.scraper_status s where s.source is not null and s.source <> ''
        union select 'contorion'::text
        union select 'bauportal'::text
      ) q
      where lower(src) not in ('manomano.fr','manomano.de','manomano_fr','manomano_de')
    ), array[]::text[]) into v_scrapers;
  else
    with normalized as (
      select regexp_replace(lower(coalesce(x,'')), '[^a-z0-9]+', '', 'g') as norm
      from unnest(p_scrapers) as t(x)
    )
    select coalesce(array_agg(distinct mapped), array[]::text[])
    into v_scrapers
    from (
      select case
        when norm = 'banemo' then 'banemo'
        when norm = 'bauhaus' then 'bauhaus'
        when norm like 'bauportal%' then 'bauportal'
        when norm = 'contorion' then 'contorion'
        when norm = 'elektrokoeck' then 'elektrokoeck'
        when norm = 'geizhals' then 'geizhals'
        when norm = 'gotools' then 'gotools'
        when norm = 'lefeld' then 'lefeld'
        when norm = 'siko' then 'siko'
        when norm = 'technikdirekt' then 'technikdirekt'
        when norm = 'voelkner' then 'voelkner'
        when norm like '%manomano%de%' then 'manomano_de'
        when norm like '%manomano%fr%' then 'manomano_fr'
        when norm = 'manomanode' then 'manomano_de'
        when norm = 'manomanofr' then 'manomano_fr'
        else null
      end as mapped
      from normalized
    ) m
    where mapped is not null;
  end if;

  with excluded_eans as (
    select distinct h.ean
    from public.mv_mr_keyword_blacklist_hits h
    where h.source = any(v_scrapers)
  ),
  base as (
    select
      p.ean,
      count(distinct p.source)::bigint as sources_count,
      min(coalesce(p.price, 0)::numeric) as min_price,
      max(coalesce(p.price, 0)::numeric) as max_price
    from public.mv_products_current p
    where p.source = any(v_scrapers)
      and p.ean is not null
      and p.ean <> ''
      and (
        public.normalize_search_de(p.ean) like v_like
        or public.normalize_search_de(coalesce(p.name, '')) like v_like
      )
      and not exists (select 1 from public.mv_bauhaus_blacklist_eans b where b.ean = p.ean)
      and not exists (select 1 from excluded_eans x where x.ean = p.ean)
      and not exists (select 1 from public.deals_ean_blacklist bl where bl.ean = p.ean)
    group by p.ean
  ),
  deals as (
    select
      b.ean,
      b.sources_count,
      b.min_price,
      b.max_price,
      case
        when b.max_price > 0 and b.max_price > b.min_price
          then ((b.max_price - b.min_price) / b.max_price) * 100
        else 0::numeric
      end as discount_pct
    from base b
  ),
  candidates as (
    select d.ean
    from deals d
    where d.sources_count >= greatest(1, coalesce(p_min_sources, 1))
      and d.discount_pct >= greatest(0, coalesce(p_min_savings, 0))
      and (p_price_min is null or d.min_price >= p_price_min)
      and (p_price_max is null or d.min_price <= p_price_max)
  )
  insert into public.deals_ean_blacklist (ean, note)
  select c.ean, nullif(trim(coalesce(p_note,'')), '')
  from candidates c
  on conflict (ean) do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;


ALTER FUNCTION "public"."add_deals_ean_blacklist_from_search"("p_search" "text", "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[], "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."attach_scraper_sync_trigger"("p_table" "regclass") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_table text := p_table::text;
  v_trigger text;
begin
  v_trigger := replace(v_table, '.', '_') || '_sync_to_products_trg';

  execute format('drop trigger if exists %I on %s;', v_trigger, v_table);
  execute format(
    'create trigger %I after insert or update on %s for each row execute function public.sync_any_scraper_product_to_products();',
    v_trigger, v_table
  );
end;
$$;


ALTER FUNCTION "public"."attach_scraper_sync_trigger"("p_table" "regclass") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_mr_compatible_voelkner"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.source = 'voelkner' THEN
    IF NEW.mr_weight_kg IS NOT NULL AND NEW.mr_weight_kg > 25 THEN
      NEW.mr_compatible = false;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_mr_compatible_voelkner"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_price_snapshot"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.price IS NOT NULL AND NEW.source = 'werkzeug_guenstig' THEN
    INSERT INTO price_snapshots (product_id, price_current, in_stock, scraped_at)
    VALUES (NEW.id, NEW.price, NEW.in_stock, NOW())
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_price_snapshot"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bootstrap_all_scraper_triggers"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare
  r record;
begin
  for r in
    select format('%I.%I', schemaname, tablename)::regclass as tbl
    from pg_tables
    where schemaname = 'public'
      and tablename like '%\_products' escape '\'
      and tablename <> 'products'
  loop
    perform public.attach_scraper_sync_trigger(r.tbl);
  end loop;
end;
$$;


ALTER FUNCTION "public"."bootstrap_all_scraper_triggers"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_deals_ean_blacklist"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_deleted integer;
begin
  delete from public.deals_ean_blacklist;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;


ALTER FUNCTION "public"."clear_deals_ean_blacklist"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."extract_max_dim_cm"("specs" "jsonb") RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
  dim_keys text[] := ARRAY[
    'Maße (L x B x H)', 'Abmessungen', 'Außenmaße',
    'Länge', 'Breite', 'Höhe', 'Tiefe', 'Durchmesser',
    'Max. Außenlänge', 'Length', 'Width', 'Height', 'Depth'
  ];
  k       text;
  raw_val text;
  nums    text[];
  max_val numeric := NULL;
  v       numeric;
  has_cm  boolean;
  has_mm  boolean;
  cleaned text;
BEGIN
  FOREACH k IN ARRAY dim_keys LOOP
    raw_val := specs ->> k;
    IF raw_val IS NULL THEN CONTINUE; END IF;

    has_cm := lower(raw_val) LIKE '%cm%';
    has_mm := lower(raw_val) LIKE '%mm%';

    -- Ignorer les valeurs sans unité de longueur explicite
    IF NOT has_cm AND NOT has_mm THEN CONTINUE; END IF;

    -- Normalisation du format numérique ALLEMAND avant extraction :
    -- "2.800"  → "2800"  (point séparateur de milliers : 3 chiffres après)
    -- "11,64"  → "11.64" (virgule = décimale)
    -- "1.234,5"→ "1234.5"
    cleaned := raw_val;

    -- Cas "1.234,56" : virgule ET point → supprimer les points, remplacer virgule
    IF cleaned ~ '\d\.\d{3}' AND cleaned ~ '\d,\d' THEN
      cleaned := replace(cleaned, '.', '');
      cleaned := replace(cleaned, ',', '.');

    -- Cas "2.800" : point suivi de 3 chiffres = milliers
    ELSIF cleaned ~ '\d\.\d{3}' THEN
      cleaned := replace(cleaned, '.', '');

    -- Cas "11,64" : virgule = décimale
    ELSIF cleaned ~ '\d,\d' THEN
      cleaned := replace(cleaned, ',', '.');
    END IF;

    -- Extraire tous les nombres du texte nettoyé
    SELECT array_agg(m)
    INTO nums
    FROM regexp_matches(cleaned, '\d+(?:\.\d+)?', 'g') AS t(m);

    IF nums IS NULL THEN CONTINUE; END IF;

    SELECT max(
      CASE
        WHEN has_mm AND NOT has_cm THEN x::numeric / 10   -- mm → cm
        ELSE x::numeric                                    -- déjà en cm
      END
    ) INTO v
    FROM unnest(nums) x;

    IF v IS NOT NULL AND (max_val IS NULL OR v > max_val) THEN
      max_val := v;
    END IF;
  END LOOP;

  RETURN max_val;
END;
$$;


ALTER FUNCTION "public"."extract_max_dim_cm"("specs" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."extract_pack_quantity"("name" "text") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $_$
DECLARE
  match text;
  qty integer;
BEGIN
  -- Priorité 1: VE/VPE/Verpackungseinheit X Stück
  match := substring(name from '(?i)(?:VPE|Verpackungseinheit|Verpackungsinhalt)[:\s]+(\d[\d\.]*)\s*(?:Stück|Stk\.?|St\.?|tlg\.?)');
  IF match IS NOT NULL THEN
    RETURN replace(match, '.', '')::integer;
  END IF;

  -- Priorité 2: VE suivi directement d'un nombre (ex: VE1, VE 10)
  match := substring(name from '(?i)\bVE\s*(\d+)\b');
  IF match IS NOT NULL THEN
    RETURN replace(match, '.', '')::integer;
  END IF;

  -- Priorité 3: Inhalt: X Stück
  match := substring(name from '(?i)Inhalt[:\s]+(\d[\d\.]*)\s*(?:Stück|Stk\.?|St\.?)');
  IF match IS NOT NULL THEN
    RETURN replace(match, '.', '')::integer;
  END IF;
  
  -- Priorité 4: X tlg / X Stück / X er-Pack
  match := substring(name from '(\d[\d\.]*)\s*(?:er(?:-(?:Pack|Box|Beutel))?|Stück|Stk\.?|tlg\.?|St\.?)(?:\s|\.|\b|$)');
  IF match IS NOT NULL THEN
    qty := replace(match, '.', '')::integer;
    IF qty NOT BETWEEN 1900 AND 2099 THEN
      RETURN qty;
    END IF;
  END IF;
  
  RETURN 1;
END;
$_$;


ALTER FUNCTION "public"."extract_pack_quantity"("name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."extract_weight_kg"("specs" "jsonb") RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $_$
DECLARE
  weight_keys text[] := ARRAY[
    'Gewicht (Netto)', 'Gewicht', 'Gesamtgewicht', 'Eigengewicht',
    'Net weight', 'Weight', 'Produktgewicht', 'Artikelgewicht'
  ];
  k       text;
  raw_val text;
  cleaned text;
  n       numeric;
BEGIN
  FOREACH k IN ARRAY weight_keys LOOP
    raw_val := specs ->> k;
    IF raw_val IS NOT NULL THEN
      cleaned := regexp_replace(
        replace(raw_val, ',', '.'),
        '[^0-9.]', '', 'g'
      );
      IF cleaned ~ '^\d+\.?\d*$' THEN
        n := cleaned::numeric;
        -- Grammes : contient ' g' ou 'g' mais PAS 'kg'
        IF lower(raw_val) ~ ' g$' OR lower(raw_val) ~ '^[0-9,\. ]+g$' THEN
          IF lower(raw_val) NOT LIKE '%kg%' THEN
            RETURN n / 1000;
          END IF;
        END IF;
        RETURN n;
      END IF;
    END IF;
  END LOOP;
  RETURN NULL;
END;
$_$;


ALTER FUNCTION "public"."extract_weight_kg"("specs" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_ean_from_payload"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_ean text;
begin
  if new.ean is null or btrim(new.ean) = '' then
    v_ean := coalesce(
      nullif(new.specs->>'EAN', ''),
      nullif((regexp_match(coalesce(new.specs->>'Details',''), '(?i)\bEAN\D*([0-9]{8,14})\b'))[1], ''),
      nullif((regexp_match(coalesce(new.description,''), '(?i)\bEAN\D*([0-9]{8,14})\b'))[1], '')
    );

    if v_ean is not null then
      new.ean := v_ean;
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."fill_ean_from_payload"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fix_pack_quantity_by_consensus"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.products p
  SET pack_quantity = consensus.qty
  FROM (
    SELECT ean, pack_quantity as qty, count(*) as cnt
    FROM public.products
    WHERE ean IS NOT NULL AND ean <> ''
      AND pack_quantity > 1
    GROUP BY ean, pack_quantity
    HAVING count(*) >= 1
  ) consensus
  WHERE p.ean = consensus.ean
    AND p.pack_quantity = 1
    AND consensus.qty > 1;
END;
$$;


ALTER FUNCTION "public"."fix_pack_quantity_by_consensus"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_active_blitzangebote"("limit_count" integer DEFAULT 50) RETURNS TABLE("id" "uuid", "name" "text", "current_price" numeric, "before_price" numeric, "drop_pct" numeric, "deal_end_timestamp" bigint, "deal_end_date" timestamp with time zone, "hours_remaining" numeric, "product_url" "text", "image_url" "text", "is_sale" boolean, "brand_name" "text", "voelkner_id" character varying, "ean" "text", "stock_available" boolean)
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    current_rec RECORD;
BEGIN
    FOR current_rec IN
        SELECT 
            p.id,
            p.name,
            ps.price_current AS current_price,
            ps.price_before AS before_price,
            ps.drop_percent AS drop_pct,
            p.deal_end_timestamp,
            p.deal_end_date,
            ROUND(EXTRACT(epoch FROM (p.deal_end_date - NOW())) / 3600, 1) AS hours_remaining,
            p.product_url,
            p.image_url,
            p.is_sale,
            p.brand_name,
            p.voelkner_id,
            p.ean,
            ps.in_stock AS stock_available  -- ← Alias ICI
        FROM products p
        LEFT JOIN LATERAL (
            SELECT 
                price_current,
                price_before,
                drop_percent,
                in_stock,
                scraped_at
            FROM price_snapshots
            WHERE product_id = p.id
            ORDER BY scraped_at DESC
            LIMIT 1
        ) ps ON TRUE
        WHERE p.is_blitzangebot = TRUE
          AND p.deal_end_timestamp IS NOT NULL
          AND p.deal_end_timestamp > EXTRACT(epoch FROM NOW())
          AND (ps.in_stock = TRUE OR ps.in_stock IS NULL)
        ORDER BY p.deal_end_timestamp ASC
        LIMIT limit_count
    LOOP
        id := current_rec.id;
        name := current_rec.name;
        current_price := current_rec.current_price;
        before_price := current_rec.before_price;
        drop_pct := current_rec.drop_pct;
        deal_end_timestamp := current_rec.deal_end_timestamp;
        deal_end_date := current_rec.deal_end_date;
        hours_remaining := current_rec.hours_remaining;
        product_url := current_rec.product_url;
        image_url := current_rec.image_url;
        is_sale := current_rec.is_sale;
        brand_name := current_rec.brand_name;
        voelkner_id := current_rec.voelkner_id;
        ean := current_rec.ean;
        stock_available := current_rec.stock_available;
        RETURN NEXT;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."get_active_blitzangebote"("limit_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_best_deals"("min_savings_pct" numeric DEFAULT 10, "max_results" integer DEFAULT 100) RETURNS TABLE("ean" "text", "nb_sources" bigint, "prix_min" numeric, "prix_max" numeric, "economie_pct" numeric)
    LANGUAGE "sql" STABLE
    AS $$
  SELECT
    p.ean::TEXT,
    COUNT(DISTINCT p.source)::BIGINT,
    MIN(p.price)::NUMERIC,
    MAX(p.price)::NUMERIC,
    ROUND(((MAX(p.price) - MIN(p.price)) / NULLIF(MAX(p.price), 0) * 100)::NUMERIC, 2)
  FROM public.mv_products_current p
  WHERE p.ean IS NOT NULL
    AND p.ean <> ''
    AND p.price > 0
    AND p.in_stock = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.deals_ean_blacklist bl
      WHERE bl.ean = p.ean
    )
  GROUP BY p.ean
  HAVING COUNT(DISTINCT p.source) >= 2
     AND ((MAX(p.price) - MIN(p.price)) / NULLIF(MAX(p.price), 0) * 100) >= min_savings_pct
     AND ((MAX(p.price) - MIN(p.price)) / NULLIF(MAX(p.price), 0) * 100) <= 90
  ORDER BY 5 DESC
  LIMIT max_results;
$$;


ALTER FUNCTION "public"."get_best_deals"("min_savings_pct" numeric, "max_results" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_dashboard_stats"() RETURNS json
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  result JSON;
BEGIN
  SELECT json_build_object(
    'total_products', (SELECT COUNT(*) FROM products),
    'total_with_ean', (SELECT COUNT(*) FROM products WHERE ean IS NOT NULL),
    'total_with_price', (SELECT COUNT(*) FROM products WHERE price > 0),
    'total_in_stock', (SELECT COUNT(*) FROM products WHERE in_stock = true),
    'total_deals', (
      SELECT COUNT(DISTINCT ean) 
      FROM products 
      WHERE ean IN (
        SELECT ean 
        FROM products 
        WHERE ean IS NOT NULL AND price > 0 AND in_stock = true
        GROUP BY ean 
        HAVING COUNT(DISTINCT source) >= 2
      )
    ),
    'avg_savings', (
      SELECT ROUND(AVG((MAX(price) - MIN(price)) / NULLIF(MAX(price), 0) * 100)::numeric, 2)
      FROM products 
      WHERE ean IS NOT NULL AND price > 0 AND in_stock = true
      GROUP BY ean
      HAVING COUNT(DISTINCT source) >= 2
    ),
    'sources', (
      SELECT json_agg(json_build_object('name', source, 'count', cnt) ORDER BY cnt DESC)
      FROM (
        SELECT source, COUNT(*) as cnt 
        FROM products 
        GROUP BY source
      ) s
    )
  ) INTO result;
  
  RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_dashboard_stats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_deals_count_mr"("p_min_savings" numeric DEFAULT 0, "p_min_sources" integer DEFAULT 1, "p_price_min" numeric DEFAULT NULL::numeric, "p_price_max" numeric DEFAULT NULL::numeric, "p_scrapers" "text"[] DEFAULT NULL::"text"[]) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare
  v_count integer;
  v_price_min numeric := case when p_price_min is null then null else greatest(0, p_price_min) end;
  v_price_max numeric := case when p_price_max is null then null else greatest(0, p_price_max) end;
begin
  if v_price_min is not null and v_price_max is not null and v_price_max < v_price_min then
    v_price_max := v_price_min;
  end if;

  if p_scrapers is null or coalesce(array_length(p_scrapers,1),0)=0 or coalesce(array_length(p_scrapers,1),0) >= 5 then
    select count(*)::int into v_count
    from public.v_deals_blacklist_filtered d
    where d.sources_count >= greatest(1, coalesce(p_min_sources, 1))
      and d.discount_pct >= greatest(0, coalesce(p_min_savings, 0))
      and (v_price_min is null or d.min_price >= v_price_min)
      and (v_price_max is null or d.min_price <= v_price_max);
    return coalesce(v_count, 0);
  end if;

  with normalized as (
    select distinct regexp_replace(lower(coalesce(x,'')), '[^a-z0-9]+', '', 'g') as norm
    from unnest(p_scrapers) as t(x)
    where coalesce(trim(x),'') <> ''
  ),
  mapped_scrapers as (
    select distinct case
      when norm = 'alternate' then 'alternate'
      when norm = 'banemo' then 'banemo'
      when norm = 'bauhaus' then 'bauhaus'
      when norm like 'bauportal%' then 'bauportal'
      when norm = 'biebrach' then 'biebrach'
      when norm = 'contorion' then 'contorion'
      when norm = 'elektrokoeck' then 'elektrokoeck'
      when norm = 'etrona' then 'etrona'
      when norm = 'fiduciashop' then 'fiduciashop'
      when norm = 'gotools' then 'gotools'
      when norm = 'kirchner24' then 'kirchner24'
      when norm = 'lefeld' then 'lefeld'
      when norm = 'mounaco' then 'mounaco'
      when norm = 'playox' then 'playox'
      when norm = 'proshop' then 'proshop'
      when norm = 'rubart' then 'rubart'
      when norm = 'siko' then 'siko'
      when norm = 'technikdirekt' then 'technikdirekt'
      when norm = 'toolineo' then 'toolineo'
      when norm = 'tuul' then 'tuul'
      when norm = 'voelkner' then 'voelkner'
      when norm like '%manomano%de%' then 'manomano_de'
      when norm like '%manomano%fr%' then 'manomano_fr'
      when norm = 'manomanode' then 'manomano_de'
      when norm = 'manomanofr' then 'manomano_fr'
      when norm like '%werkzeug%guenstig%' then 'werkzeug_guenstig'
      when norm = 'werkzeugguenstig' then 'werkzeug_guenstig'
      when norm = 'werkzeuggunstig' then 'werkzeug_guenstig'
      else null
    end as source
    from normalized
  ),
  raw_products as (
    select p.ean, p.source, p.unit_price::numeric as price
    from public.mv_products_unit_price p
    where p.source in (select source from mapped_scrapers where source is not null)
      and p.ean is not null and p.ean <> ''
      and p.unit_price is not null and p.unit_price > 0
    union all
    select bp.ean, 'bauportal'::text as source, bp.price::numeric as price
    from public.bauportal_products bp
    where 'bauportal' in (select source from mapped_scrapers)
      and bp.ean is not null and bp.ean <> ''
      and bp.price is not null and bp.price > 0
  ),
  excluded_eans as (
    select distinct h.ean
    from public.mv_mr_keyword_blacklist_hits h
    where h.source in (select source from mapped_scrapers where source is not null)
  ),
  by_ean as (
    select p.ean,
           count(distinct p.source)::bigint as sources_count,
           min(p.price) as min_price,
           max(p.price) as max_price
    from raw_products p
    where not exists (select 1 from public.mv_bauhaus_blacklist_eans b where b.ean = p.ean)
      and not exists (select 1 from excluded_eans x where x.ean = p.ean)
      and not exists (select 1 from public.deals_ean_blacklist bl where bl.ean = p.ean)
    group by p.ean
  ),
  scored as (
    select b.*,
           case 
             when b.max_price > 0 and b.max_price > b.min_price
               and b.max_price <= b.min_price * 10
             then ((b.max_price - b.min_price)/b.max_price)*100 
             else 0::numeric 
           end as discount_pct
    from by_ean b
  )
  select count(*)::int into v_count
  from scored s
  where s.sources_count >= greatest(1, coalesce(p_min_sources, 1))
    and s.discount_pct >= greatest(0, coalesce(p_min_savings, 0))
    and (v_price_min is null or s.min_price >= v_price_min)
    and (v_price_max is null or s.min_price <= v_price_max);

  return coalesce(v_count, 0);
end;
$$;


ALTER FUNCTION "public"."get_deals_count_mr"("p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_deals_count_mr_search"("p_search" "text", "p_min_savings" numeric DEFAULT 0, "p_min_sources" integer DEFAULT 1, "p_price_min" numeric DEFAULT NULL::numeric, "p_price_max" numeric DEFAULT NULL::numeric, "p_scrapers" "text"[] DEFAULT NULL::"text"[]) RETURNS integer
    LANGUAGE "plpgsql" STABLE
    SET "statement_timeout" TO '30s'
    AS $_$
declare
  v_count integer;
  v_search text := trim(coalesce(p_search, ''));
  v_search_norm text;
  v_is_ean boolean := false;
  v_like text;
  v_scrapers text[];
begin
  if v_search = '' then
    return 0;
  end if;

  v_search_norm := public.normalize_search_de(v_search);
  v_is_ean := v_search_norm ~ '^[0-9]{8,14}$';
  v_like := '%' || v_search_norm || '%';

  if p_scrapers is null then
    select coalesce(array(
      select src from (
        select s.source as src from public.scraper_status s where s.source is not null and s.source <> ''
        union select 'contorion'::text
        union select 'bauportal'::text
      ) q
      where lower(src) not in ('manomano.fr','manomano.de','manomano_fr','manomano_de')
    ), array[]::text[]) into v_scrapers;
  else
    with normalized as (
      select regexp_replace(lower(coalesce(x,'')), '[^a-z0-9]+', '', 'g') as norm
      from unnest(p_scrapers) as t(x)
    )
    select coalesce(array_agg(distinct mapped), array[]::text[])
    into v_scrapers
    from (
      select case
        when norm = 'banemo' then 'banemo'
        when norm = 'bauhaus' then 'bauhaus'
        when norm like 'bauportal%' then 'bauportal'
        when norm = 'contorion' then 'contorion'
        when norm = 'elektrokoeck' then 'elektrokoeck'
        when norm = 'geizhals' then 'geizhals'
        when norm = 'gotools' then 'gotools'
        when norm = 'lefeld' then 'lefeld'
        when norm = 'siko' then 'siko'
        when norm = 'technikdirekt' then 'technikdirekt'
        when norm = 'voelkner' then 'voelkner'
        when norm like '%manomano%de%' then 'manomano_de'
        when norm like '%manomano%fr%' then 'manomano_fr'
        when norm = 'manomanode' then 'manomano_de'
        when norm = 'manomanofr' then 'manomano_fr'
        else null
      end as mapped
      from normalized
    ) m
    where mapped is not null;
  end if;

  with candidate_eans as (
    select distinct p.ean
    from public.mv_products_current p
    where p.source = any(v_scrapers)
      and p.ean is not null and p.ean <> ''
      and (
        (v_is_ean and p.ean = v_search_norm)
        or
        (not v_is_ean and (
          public.normalize_search_de(p.ean) like v_like
          or public.normalize_search_de(coalesce(p.name, '')) like v_like
        ))
      )

    union

    select distinct bp.ean
    from public.bauportal_products bp
    where 'bauportal' = any(v_scrapers)
      and bp.ean is not null and bp.ean <> ''
      and (
        (v_is_ean and bp.ean = v_search_norm)
        or
        (not v_is_ean and (
          public.normalize_search_de(bp.ean) like v_like
          or public.normalize_search_de(coalesce(bp.name, '')) like v_like
        ))
      )
  ),
  filtered_eans as (
    select c.ean
    from candidate_eans c
    where not exists (select 1 from public.mv_bauhaus_blacklist_eans b where b.ean = c.ean)
      and not exists (
        select 1
        from public.mv_mr_keyword_blacklist_hits h
        where h.ean = c.ean
          and h.source = any(v_scrapers)
      )
      and not exists (select 1 from public.deals_ean_blacklist bl where bl.ean = c.ean)
  ),
  raw_products as (
    select p.ean, p.source, coalesce(p.price,0)::numeric as price
    from public.mv_products_current p
    join filtered_eans f on f.ean = p.ean
    where p.source = any(v_scrapers)

    union all

    select bp.ean, 'bauportal'::text as source, coalesce(bp.price,0)::numeric as price
    from public.bauportal_products bp
    join filtered_eans f on f.ean = bp.ean
    where 'bauportal' = any(v_scrapers)
  ),
  by_ean as (
    select
      p.ean,
      count(distinct p.source)::bigint as sources_count,
      min(p.price) as min_price,
      max(p.price) as max_price
    from raw_products p
    group by p.ean
  ),
  deals as (
    select
      b.*,
      case
        when b.max_price > 0 and b.max_price > b.min_price
          then ((b.max_price - b.min_price) / b.max_price) * 100
        else 0::numeric
      end as discount_pct
    from by_ean b
  )
  select count(*)::int
  into v_count
  from deals d
  where d.sources_count >= greatest(1, coalesce(p_min_sources, 1))
    and d.discount_pct >= greatest(0, coalesce(p_min_savings, 0))
    and (p_price_min is null or d.min_price >= p_price_min)
    and (p_price_max is null or d.min_price <= p_price_max);

  return coalesce(v_count, 0);
end;
$_$;


ALTER FUNCTION "public"."get_deals_count_mr_search"("p_search" "text", "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_deals_page_mr"("p_page" integer DEFAULT 1, "p_page_size" integer DEFAULT 20, "p_min_savings" numeric DEFAULT 0, "p_min_sources" integer DEFAULT 1, "p_price_min" numeric DEFAULT NULL::numeric, "p_price_max" numeric DEFAULT NULL::numeric, "p_sort_by" "text" DEFAULT 'discount_pct'::"text", "p_sort_dir" "text" DEFAULT 'desc'::"text", "p_scrapers" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("ean" "text", "sources_count" bigint, "min_price" numeric, "max_price" numeric, "discount_pct" numeric, "best_product_id" "uuid", "best_source" "text", "best_product_url" "text", "best_normalized_price" numeric, "best_pack_quantity" integer)
    LANGUAGE "plpgsql"
    AS $$
declare
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_size integer := least(200, greatest(1, coalesce(p_page_size, 20)));
  v_offset integer := (v_page - 1) * v_size;
  v_sort_by text := case lower(coalesce(p_sort_by, 'discount_pct'))
    when 'discount_pct' then 'discount_pct'
    when 'min_price' then 'min_price'
    when 'max_price' then 'max_price'
    when 'sources_count' then 'sources_count'
    when 'ean' then 'ean'
    when 'best_source' then 'best_source'
    when 'scraper' then 'best_source'
    else 'discount_pct'
  end;
  v_sort_dir text := case lower(coalesce(p_sort_dir, 'desc')) when 'asc' then 'asc' else 'desc' end;
  v_price_min numeric := case when p_price_min is null then null else greatest(0, p_price_min) end;
  v_price_max numeric := case when p_price_max is null then null else greatest(0, p_price_max) end;
begin
  if v_price_min is not null and v_price_max is not null and v_price_max < v_price_min then
    v_price_max := v_price_min;
  end if;

  if p_scrapers is null or coalesce(array_length(p_scrapers,1),0)=0 or coalesce(array_length(p_scrapers,1),0) >= 20 then
    return query
    select
      d.ean, d.sources_count, d.min_price, d.max_price, d.discount_pct,
      d.best_product_id, d.best_source, d.best_product_url, d.best_normalized_price, d.best_pack_quantity
    from public.v_deals_blacklist_filtered d
    where d.sources_count >= greatest(1, coalesce(p_min_sources, 1))
      and d.discount_pct >= greatest(0, coalesce(p_min_savings, 0))
      and (v_price_min is null or d.min_price >= v_price_min)
      and (v_price_max is null or d.min_price <= v_price_max)
    order by
      case when v_sort_by='discount_pct' and v_sort_dir='asc' then d.discount_pct end asc,
      case when v_sort_by='discount_pct' and v_sort_dir='desc' then d.discount_pct end desc,
      case when v_sort_by='min_price' and v_sort_dir='asc' then d.min_price end asc,
      case when v_sort_by='min_price' and v_sort_dir='desc' then d.min_price end desc,
      case when v_sort_by='max_price' and v_sort_dir='asc' then d.max_price end asc,
      case when v_sort_by='max_price' and v_sort_dir='desc' then d.max_price end desc,
      case when v_sort_by='sources_count' and v_sort_dir='asc' then d.sources_count end asc,
      case when v_sort_by='sources_count' and v_sort_dir='desc' then d.sources_count end desc,
      case when v_sort_by='ean' and v_sort_dir='asc' then d.ean end asc,
      case when v_sort_by='ean' and v_sort_dir='desc' then d.ean end desc,
      case when v_sort_by='best_source' and v_sort_dir='asc' then d.best_source end asc,
      case when v_sort_by='best_source' and v_sort_dir='desc' then d.best_source end desc,
      d.ean asc
    offset v_offset limit v_size;
    return;
  end if;

  return query
  with normalized as (
    select distinct regexp_replace(lower(coalesce(x,'')), '[^a-z0-9]+', '', 'g') as norm
    from unnest(p_scrapers) as t(x)
    where coalesce(trim(x),'') <> ''
  ),
  mapped_scrapers as (
    select distinct case
      when norm = 'alternate' then 'alternate'
      when norm = 'banemo' then 'banemo'
      when norm = 'bauhaus' then 'bauhaus'
      when norm like 'bauportal%' then 'bauportal'
      when norm = 'biebrach' then 'biebrach'
      when norm = 'contorion' then 'contorion'
      when norm = 'elektrokoeck' then 'elektrokoeck'
      when norm = 'etrona' then 'etrona'
      when norm = 'fiduciashop' then 'fiduciashop'
      when norm = 'gotools' then 'gotools'
      when norm = 'kirchner24' then 'kirchner24'
      when norm = 'lefeld' then 'lefeld'
      when norm = 'mounaco' then 'mounaco'
      when norm = 'playox' then 'playox'
      when norm = 'proshop' then 'proshop'
      when norm = 'rubart' then 'rubart'
      when norm = 'siko' then 'siko'
      when norm = 'technikdirekt' then 'technikdirekt'
      when norm = 'toolineo' then 'toolineo'
      when norm = 'tuul' then 'tuul'
      when norm = 'voelkner' then 'voelkner'
      when norm like '%manomano%de%' then 'manomano_de'
      when norm like '%manomano%fr%' then 'manomano_fr'
      when norm = 'manomanode' then 'manomano_de'
      when norm = 'manomanofr' then 'manomano_fr'
      when norm like '%werkzeug%guenstig%' then 'werkzeug_guenstig'
      when norm = 'werkzeugguenstig' then 'werkzeug_guenstig'
      when norm = 'werkzeuggunstig' then 'werkzeug_guenstig'
      else null
    end as source
    from normalized
  ),
  raw_products as materialized (
    select p.id, p.ean, p.source, p.product_url,
           p.unit_price::numeric as price,
           p.pack_quantity::integer as pack_qty
    from public.mv_products_unit_price p
    where p.source in (select source from mapped_scrapers where source is not null)
      and p.ean is not null and p.ean <> ''
      and p.unit_price is not null and p.unit_price > 0
    union all
    select bp.id, bp.ean, 'bauportal'::text as source, bp.product_url,
           bp.price::numeric as price,
           1::integer as pack_qty
    from public.bauportal_products bp
    where 'bauportal' in (select source from mapped_scrapers)
      and bp.ean is not null and bp.ean <> ''
      and bp.price is not null and bp.price > 0
  ),
  excluded_eans as materialized (
    select distinct h.ean
    from public.mv_mr_keyword_blacklist_hits h
    where h.source in (select source from mapped_scrapers where source is not null)
  ),
  by_ean as materialized (
    select p.ean,
           count(distinct p.source)::bigint as sources_count,
           min(p.price) as min_price,
           max(p.price) as max_price
    from raw_products p
    where not exists (select 1 from public.mv_bauhaus_blacklist_eans b where b.ean = p.ean)
      and not exists (select 1 from excluded_eans x where x.ean = p.ean)
      and not exists (select 1 from public.deals_ean_blacklist bl where bl.ean = p.ean)
    group by p.ean
  ),
  scored as materialized (
    select b.ean, b.sources_count, b.min_price, b.max_price,
           case 
             when b.max_price > 0 
               and b.max_price > b.min_price
               and b.max_price <= b.min_price * 10
             then ((b.max_price - b.min_price)/b.max_price)*100 
             else 0::numeric 
           end as discount_pct
    from by_ean b
    where b.sources_count >= greatest(1, coalesce(p_min_sources, 1))
      and (v_price_min is null or b.min_price >= v_price_min)
      and (v_price_max is null or b.min_price <= v_price_max)
  ),
  page_rows as materialized (
    select s.*
    from scored s
    where s.discount_pct >= greatest(0, coalesce(p_min_savings, 0))
    order by
      case when v_sort_by='discount_pct' and v_sort_dir='asc' then s.discount_pct end asc,
      case when v_sort_by='discount_pct' and v_sort_dir='desc' then s.discount_pct end desc,
      case when v_sort_by='min_price' and v_sort_dir='asc' then s.min_price end asc,
      case when v_sort_by='min_price' and v_sort_dir='desc' then s.min_price end desc,
      case when v_sort_by='max_price' and v_sort_dir='asc' then s.max_price end asc,
      case when v_sort_by='max_price' and v_sort_dir='desc' then s.max_price end desc,
      case when v_sort_by='sources_count' and v_sort_dir='asc' then s.sources_count end asc,
      case when v_sort_by='sources_count' and v_sort_dir='desc' then s.sources_count end desc,
      case when v_sort_by='ean' and v_sort_dir='asc' then s.ean end asc,
      case when v_sort_by='ean' and v_sort_dir='desc' then s.ean end desc,
      s.ean asc
    offset v_offset limit v_size
  ),
  best_offer as (
    select distinct on (p.ean)
      p.ean,
      p.id as best_product_id,
      p.source as best_source,
      p.product_url as best_product_url,
      p.price as best_normalized_price,
      p.pack_qty as best_pack_quantity
    from raw_products p
    join page_rows r on r.ean = p.ean
    order by p.ean, p.price asc nulls last, p.id
  )
  select r.ean, r.sources_count, r.min_price, r.max_price, r.discount_pct,
         bo.best_product_id, bo.best_source, bo.best_product_url, bo.best_normalized_price, bo.best_pack_quantity
  from page_rows r
  left join best_offer bo on bo.ean = r.ean
  order by
    case when v_sort_by='discount_pct' and v_sort_dir='asc' then r.discount_pct end asc,
    case when v_sort_by='discount_pct' and v_sort_dir='desc' then r.discount_pct end desc,
    case when v_sort_by='min_price' and v_sort_dir='asc' then r.min_price end asc,
    case when v_sort_by='min_price' and v_sort_dir='desc' then r.min_price end desc,
    case when v_sort_by='max_price' and v_sort_dir='asc' then r.max_price end asc,
    case when v_sort_by='max_price' and v_sort_dir='desc' then r.max_price end desc,
    case when v_sort_by='sources_count' and v_sort_dir='asc' then r.sources_count end asc,
    case when v_sort_by='sources_count' and v_sort_dir='desc' then r.sources_count end desc,
    case when v_sort_by='ean' and v_sort_dir='asc' then r.ean end asc,
    case when v_sort_by='ean' and v_sort_dir='desc' then r.ean end desc,
    case when v_sort_by='best_source' and v_sort_dir='asc' then bo.best_source end asc,
    case when v_sort_by='best_source' and v_sort_dir='desc' then bo.best_source end desc,
    r.ean asc;
end;
$$;


ALTER FUNCTION "public"."get_deals_page_mr"("p_page" integer, "p_page_size" integer, "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_sort_by" "text", "p_sort_dir" "text", "p_scrapers" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_deals_page_mr_search"("p_search" "text", "p_page" integer DEFAULT 1, "p_page_size" integer DEFAULT 20, "p_min_savings" numeric DEFAULT 0, "p_min_sources" integer DEFAULT 1, "p_price_min" numeric DEFAULT NULL::numeric, "p_price_max" numeric DEFAULT NULL::numeric, "p_sort_by" "text" DEFAULT 'discount_pct'::"text", "p_sort_dir" "text" DEFAULT 'desc'::"text", "p_scrapers" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("ean" "text", "sources_count" bigint, "min_price" numeric, "max_price" numeric, "discount_pct" numeric, "best_product_id" "uuid", "best_source" "text", "best_product_url" "text", "best_normalized_price" numeric, "best_pack_quantity" integer)
    LANGUAGE "plpgsql"
    AS $_$
declare
  v_search text := trim(coalesce(p_search, ''));
  v_search_norm text;
  v_is_ean boolean := false;
  v_like text;
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_size integer := least(200, greatest(1, coalesce(p_page_size, 20)));
  v_offset integer := (v_page - 1) * v_size;
  v_sort_by text;
  v_sort_dir text;
  v_scrapers text[];
begin
  if v_search = '' then
    return query
    select * from public.get_deals_page_mr(
      p_page,p_page_size,p_min_savings,p_min_sources,p_price_min,p_price_max,p_sort_by,p_sort_dir,p_scrapers
    );
    return;
  end if;

  v_search_norm := public.normalize_search_de(v_search);
  v_is_ean := v_search_norm ~ '^[0-9]{8,14}$';
  v_like := '%' || v_search_norm || '%';

  v_sort_by := case lower(coalesce(p_sort_by, 'discount_pct'))
    when 'discount_pct' then 'discount_pct' when 'min_price' then 'min_price'
    when 'max_price' then 'max_price' when 'sources_count' then 'sources_count'
    when 'ean' then 'ean' when 'best_source' then 'best_source'
    when 'scraper' then 'best_source' else 'discount_pct' end;
  v_sort_dir := case lower(coalesce(p_sort_dir, 'desc')) when 'asc' then 'asc' else 'desc' end;

  if p_scrapers is null then
    select coalesce(array(
      select distinct src from (
        select s.source as src from public.scraper_status s where s.source is not null and s.source <> ''
        union select p.source as src from public.mv_products_current p where p.source is not null and p.source <> ''
        union select 'bauportal'::text
      ) q
      where regexp_replace(lower(src), '[^a-z0-9]+', '', 'g') not in ('manomanofr','manomanode')
    ), array[]::text[]) into v_scrapers;
  else
    with normalized as (
      select distinct regexp_replace(lower(coalesce(x,'')), '[^a-z0-9]+', '', 'g') as norm
      from unnest(p_scrapers) as t(x)
      where coalesce(trim(x),'') <> ''
    )
    select coalesce(array_agg(distinct mapped), array[]::text[])
    into v_scrapers
    from (
      select case
        when norm = 'alternate' then 'alternate'
        when norm = 'banemo' then 'banemo'
        when norm = 'bauhaus' then 'bauhaus'
        when norm like 'bauportal%' then 'bauportal'
        when norm = 'biebrach' then 'biebrach'
        when norm = 'contorion' then 'contorion'
        when norm = 'elektrokoeck' then 'elektrokoeck'
        when norm = 'etrona' then 'etrona'
        when norm = 'fiduciashop' then 'fiduciashop'
        when norm = 'gotools' then 'gotools'
        when norm = 'kirchner24' then 'kirchner24'
        when norm = 'lefeld' then 'lefeld'
        when norm = 'mounaco' then 'mounaco'
        when norm = 'playox' then 'playox'
        when norm = 'proshop' then 'proshop'
        when norm = 'rubart' then 'rubart'
        when norm = 'siko' then 'siko'
        when norm = 'technikdirekt' then 'technikdirekt'
        when norm = 'toolineo' then 'toolineo'
        when norm = 'tuul' then 'tuul'
        when norm = 'voelkner' then 'voelkner'
        when norm like '%manomano%de%' then 'manomano_de'
        when norm like '%manomano%fr%' then 'manomano_fr'
        when norm = 'manomanode' then 'manomano_de'
        when norm = 'manomanofr' then 'manomano_fr'
        when norm like '%werkzeug%guenstig%' then 'werkzeug_guenstig'
        when norm = 'werkzeugguenstig' then 'werkzeug_guenstig'
        else null
      end as mapped
      from normalized
    ) m
    where mapped is not null;
  end if;

  return query
  with candidate_eans as (
    select distinct p.ean
    from public.mv_products_current p
    where p.source = any(v_scrapers)
      and p.ean is not null and p.ean <> ''
      and (
        (v_is_ean and p.ean = v_search_norm)
        or (not v_is_ean and (
          public.normalize_search_de(p.ean) like v_like
          or public.normalize_search_de(coalesce(p.name, '')) like v_like
        ))
      )
    union
    select distinct bp.ean
    from public.bauportal_products bp
    where 'bauportal' = any(v_scrapers)
      and bp.ean is not null and bp.ean <> ''
      and (
        (v_is_ean and bp.ean = v_search_norm)
        or (not v_is_ean and (
          public.normalize_search_de(bp.ean) like v_like
          or public.normalize_search_de(coalesce(bp.name, '')) like v_like
        ))
      )
  ),
  filtered_eans as (
    select c.ean from candidate_eans c
    where not exists (select 1 from public.mv_bauhaus_blacklist_eans b where b.ean = c.ean)
      and not exists (
        select 1 from public.mv_mr_keyword_blacklist_hits h
        where h.ean = c.ean and h.source = any(v_scrapers)
      )
      and not exists (select 1 from public.deals_ean_blacklist bl where bl.ean = c.ean)
  ),
  -- ← Utilise mv_products_unit_price avec unit_price au lieu de price brut
  raw_products as (
    select p.id, p.ean, p.source, p.product_url,
           p.unit_price::numeric as price,
           p.pack_quantity::integer as pack_qty
    from public.mv_products_unit_price p
    join filtered_eans fe on fe.ean = p.ean
    where p.source = any(v_scrapers)
    union all
    select bp.id, bp.ean, 'bauportal'::text as source, bp.product_url,
           (bp.price / greatest(1, coalesce(bp.pack_quantity, 1)))::numeric as price,
           coalesce(bp.pack_quantity, 1)::integer as pack_qty
    from public.bauportal_products bp
    join filtered_eans fe on fe.ean = bp.ean
    where 'bauportal' = any(v_scrapers)
      and bp.ean is not null and bp.ean <> ''
  ),
  by_ean as (
    select f.ean,
           count(distinct f.source)::bigint as sources_count,
           min(f.price) as min_price,
           max(f.price) as max_price
    from raw_products f
    group by f.ean
  ),
  scored as (
    select b.*,
           case when b.max_price > 0 and b.max_price > b.min_price
             then ((b.max_price - b.min_price) / b.max_price) * 100
             else 0::numeric end as discount_pct
    from by_ean b
    where b.sources_count >= greatest(1, coalesce(p_min_sources, 1))
      and (p_price_min is null or b.min_price >= p_price_min)
      and (p_price_max is null or b.min_price <= p_price_max)
  ),
  final_rows as (
    select s.* from scored s
    where s.discount_pct >= greatest(0, coalesce(p_min_savings, 0))
  ),
  best_offer as (
    select distinct on (f.ean)
      f.ean, f.id as best_product_id, f.source as best_source,
      f.product_url as best_product_url, f.price as best_normalized_price,
      f.pack_qty as best_pack_quantity
    from raw_products f
    order by f.ean, f.price asc nulls last, f.id
  )
  select r.ean, r.sources_count, r.min_price, r.max_price, r.discount_pct,
         bo.best_product_id, bo.best_source, bo.best_product_url,
         bo.best_normalized_price, bo.best_pack_quantity
  from final_rows r
  left join best_offer bo on bo.ean = r.ean
  order by
    case when v_sort_by='discount_pct' and v_sort_dir='asc' then r.discount_pct end asc,
    case when v_sort_by='discount_pct' and v_sort_dir='desc' then r.discount_pct end desc,
    case when v_sort_by='min_price' and v_sort_dir='asc' then r.min_price end asc,
    case when v_sort_by='min_price' and v_sort_dir='desc' then r.min_price end desc,
    case when v_sort_by='sources_count' and v_sort_dir='asc' then r.sources_count end asc,
    case when v_sort_by='sources_count' and v_sort_dir='desc' then r.sources_count end desc,
    case when v_sort_by='ean' and v_sort_dir='asc' then r.ean end asc,
    case when v_sort_by='ean' and v_sort_dir='desc' then r.ean end desc,
    case when v_sort_by='best_source' and v_sort_dir='asc' then bo.best_source end asc,
    case when v_sort_by='best_source' and v_sort_dir='desc' then bo.best_source end desc,
    r.ean asc
  offset v_offset limit v_size;
end;
$_$;


ALTER FUNCTION "public"."get_deals_page_mr_search"("p_search" "text", "p_page" integer, "p_page_size" integer, "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_sort_by" "text", "p_sort_dir" "text", "p_scrapers" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_duplicate_eans"("min_sources" integer DEFAULT 2, "min_savings_pct" numeric DEFAULT 10) RETURNS TABLE("ean" "text", "nb_sources" bigint, "nb_products" bigint, "sources" "text", "prix_min" numeric, "prix_max" numeric, "economie_pct" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.ean::TEXT,
    COUNT(DISTINCT p.source) as nb_sources,
    COUNT(*) as nb_products,
    STRING_AGG(DISTINCT p.source, ', ') as sources,
    MIN(p.price) as prix_min,
    MAX(p.price) as prix_max,
    ROUND(((MAX(p.price) - MIN(p.price)) / NULLIF(MAX(p.price), 0) * 100)::numeric, 2) as economie_pct
  FROM v_products_full p
  WHERE p.ean IS NOT NULL 
    AND p.price > 0
    AND p.in_stock = true
  GROUP BY p.ean
  HAVING COUNT(DISTINCT p.source) >= min_sources
    AND ((MAX(p.price) - MIN(p.price)) / NULLIF(MAX(p.price), 0) * 100) >= min_savings_pct
  ORDER BY economie_pct DESC
  LIMIT 100;
END;
$$;


ALTER FUNCTION "public"."get_duplicate_eans"("min_sources" integer, "min_savings_pct" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_latest_price_drops"("source_filter" "text" DEFAULT NULL::"text") RETURNS TABLE("product_id" "uuid", "name" "text", "source" "text", "price_current" numeric, "price_before" numeric, "drop_percent" numeric, "product_url" "text", "image_url" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT ON (ps.product_id)
        ps.product_id,
        p.name,
        p.source,
        ps.price_current,
        ps.price_before,
        ps.drop_percent,
        p.product_url,
        p.image_url
    FROM price_snapshots ps
    JOIN products p ON ps.product_id = p.id
    WHERE ps.scraped_at > NOW() - INTERVAL '24 hours'
      AND ps.price_before > ps.price_current
      AND (source_filter IS NULL OR p.source = source_filter)
    ORDER BY ps.product_id, ps.scraped_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_latest_price_drops"("source_filter" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_product_counts_by_source"() RETURNS TABLE("name" "text", "count" bigint)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT source::TEXT as name, COUNT(*)::BIGINT as count
  FROM products
  GROUP BY source
  ORDER BY count DESC;
END;
$$;


ALTER FUNCTION "public"."get_product_counts_by_source"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_products_count_mr"("p_price_min" numeric DEFAULT NULL::numeric, "p_price_max" numeric DEFAULT NULL::numeric, "p_scrapers" "text"[] DEFAULT NULL::"text"[]) RETURNS bigint
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_scrapers text[];
  v_price_min numeric := case when p_price_min is null then null else greatest(0, p_price_min) end;
  v_price_max numeric := case when p_price_max is null then null else greatest(0, p_price_max) end;
  v_count bigint;
begin
  if p_scrapers is null or coalesce(array_length(p_scrapers,1),0)=0 then
    select coalesce(array_agg(distinct src), array[]::text[])
    into v_scrapers
    from (
      select s.source as src
      from public.scraper_status s
      where s.source is not null and s.source <> ''
      union
      select p.source as src
      from public.mv_products_current p
      where p.source is not null and p.source <> ''
    ) q
    where lower(src) not in ('manomano.fr', 'manomano.de', 'manomano_fr', 'manomano_de');
  else
    with normalized as (
      select regexp_replace(lower(coalesce(x,'')), '[^a-z0-9]+', '', 'g') as norm
      from unnest(p_scrapers) t(x)
    )
    select coalesce(array_agg(distinct mapped), array[]::text[])
    into v_scrapers
    from (
      select case
        when norm = 'alternate' then 'alternate'
        when norm = 'banemo' then 'banemo'
        when norm = 'bauhaus' then 'bauhaus'
        when norm like 'bauportal%' then 'bauportal'
        when norm = 'contorion' then 'contorion'
        when norm = 'elektrokoeck' then 'elektrokoeck'
        when norm = 'geizhals' then 'geizhals'
        when norm = 'gotools' then 'gotools'
        when norm = 'lefeld' then 'lefeld'
        when norm = 'siko' then 'siko'
        when norm = 'technikdirekt' then 'technikdirekt'
        when norm = 'voelkner' then 'voelkner'
        when norm like '%manomano%de%' then 'manomano_de'
        when norm like '%manomano%fr%' then 'manomano_fr'
        when norm like '%werkzeug%guenstig%' then 'werkzeug_guenstig'
        when norm = 'werkzeugguenstig' then 'werkzeug_guenstig'
        when norm = 'werkzeuggunstig' then 'werkzeug_guenstig'
        else null
      end as mapped
      from normalized
    ) m
    where mapped is not null;
  end if;

  if v_price_min is not null and v_price_max is not null and v_price_max < v_price_min then
    v_price_max := v_price_min;
  end if;

  with src_eans as (
    select distinct se.ean
    from public.mv_source_eans se
    where se.source = any(v_scrapers)
      and se.ean is not null and se.ean <> ''
  ),
  ean_min_prices as (
    select p.ean, min(p.price)::numeric as min_price
    from public.mv_products_current p
    where p.source = any(v_scrapers)
      and p.ean is not null and p.ean <> ''
      and p.price is not null
    group by p.ean
  )
  select count(*)::bigint
  into v_count
  from src_eans s
  left join ean_min_prices ep on ep.ean = s.ean
  where (v_price_min is null or ep.min_price >= v_price_min)
    and (v_price_max is null or ep.min_price <= v_price_max);

  return coalesce(v_count,0);
end;
$$;


ALTER FUNCTION "public"."get_products_count_mr"("p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_products_to_translate"("p_limit" integer, "p_min_price" numeric DEFAULT 0) RETURNS TABLE("id" "uuid", "name" "text", "specs" "jsonb", "category_path" "text"[], "description" "text", "source" "text", "ean" "text")
    LANGUAGE "sql"
    AS $$
  SELECT
    t.id,
    t.name,
    t.specs,
    t.category_path,
    t.description,
    t.source,
    t.ean
  FROM public.products_to_translate t
  JOIN public.products p
    ON p.id = t.id
  WHERE p.translated_at IS NULL          -- ⭐ Empêche la boucle infinie
    AND p.price >= p_min_price           -- ⭐ Applique le filtre de prix du script Python
  ORDER BY
    CASE
      WHEN p.is_top_deal = true THEN 0
      WHEN t.ean IS NOT NULL
           AND t.ean <> ''
           AND EXISTS (
             SELECT 1
             FROM public.products p2
             WHERE p2.ean = t.ean
               AND p2.is_top_deal = true
             LIMIT 1
           ) THEN 1
      ELSE 2
    END,
    p.id
  LIMIT p_limit;
$$;


ALTER FUNCTION "public"."get_products_to_translate"("p_limit" integer, "p_min_price" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_scraper_activity"("hours_window" integer DEFAULT 1) RETURNS TABLE("source" "text", "total_produits" bigint, "nouveaux_produits" bigint, "produits_modifies" bigint, "derniere_activite" timestamp with time zone, "statut" "text", "is_currently_active" boolean, "is_functional" boolean, "vitesse_par_minute" numeric, "heures_depuis_activite" numeric)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
with ss as (
  select
    source,
    coalesce(total_produits,0)::bigint as total_produits,
    coalesce(nouveaux_1h,0)::bigint as nouveaux_1h,
    coalesce(modifies_1h,0)::bigint as modifies_1h,
    derniere_activite
  from public.scraper_status
  where source is not null and btrim(source) <> ''
),
mv as (
  select
    source,
    count(*)::bigint as total_produits
  from public.mv_products_current
  where source is not null and btrim(source) <> ''
  group by source
),
live as (
  select
    source,
    max(updated_at) as derniere_activite
  from public.products
  where source is not null and btrim(source) <> ''
  group by source
),
sources as (
  select source from ss
  union
  select source from mv
  union
  select source from live
),
base as (
  select
    s.source,
    coalesce(ss.total_produits, mv.total_produits, 0::bigint) as total_produits,
    case
      when (
        case
          when ss.derniere_activite is null then live.derniere_activite
          when live.derniere_activite is null then ss.derniere_activite
          else greatest(ss.derniere_activite, live.derniere_activite)
        end
      ) >= now() - (hours_window || ' hours')::interval
      then coalesce(ss.nouveaux_1h, 0::bigint)
      else 0::bigint
    end as nouveaux_produits,
    case
      when (
        case
          when ss.derniere_activite is null then live.derniere_activite
          when live.derniere_activite is null then ss.derniere_activite
          else greatest(ss.derniere_activite, live.derniere_activite)
        end
      ) >= now() - (hours_window || ' hours')::interval
      then coalesce(ss.modifies_1h, 0::bigint)
      else 0::bigint
    end as produits_modifies,
    case
      when ss.derniere_activite is null then live.derniere_activite
      when live.derniere_activite is null then ss.derniere_activite
      else greatest(ss.derniere_activite, live.derniere_activite)
    end as derniere_activite
  from sources s
  left join ss on ss.source = s.source
  left join mv on mv.source = s.source
  left join live on live.source = s.source
)
select
  b.source,
  b.total_produits,
  b.nouveaux_produits,
  b.produits_modifies,
  b.derniere_activite,
  case
    when b.derniere_activite >= now() - (hours_window || ' hours')::interval then '✅ ACTIF MAINTENANT'
    when b.derniere_activite >= now() - interval '24 hours' then '⏸️ FONCTIONNEL (inactif)'
    when b.derniere_activite >= now() - interval '7 days' then '⚠️ RALENTI'
    else '❌ INACTIF'
  end as statut,
  (b.derniere_activite >= now() - (hours_window || ' hours')::interval) as is_currently_active,
  (b.derniere_activite >= now() - interval '24 hours') as is_functional,
  round((b.nouveaux_produits::numeric / 60), 2) as vitesse_par_minute,
  round(extract(epoch from (now() - b.derniere_activite)) / 3600, 1) as heures_depuis_activite
from base b
order by
  (b.derniere_activite >= now() - (hours_window || ' hours')::interval) desc,
  (b.derniere_activite >= now() - interval '24 hours') desc,
  b.total_produits desc;
$$;


ALTER FUNCTION "public"."get_scraper_activity"("hours_window" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_scraper_status"() RETURNS TABLE("source" "text", "name" "text", "is_active" boolean, "is_functional" boolean, "derniere_activite" timestamp with time zone, "last_seen" timestamp with time zone, "last_update" timestamp with time zone, "total_produits" bigint, "product_count" bigint, "total_products" bigint, "nouveaux_1h" bigint, "modifies_1h" bigint, "products_last_hour" bigint, "new_products_last_hour" bigint, "price_changes_last_hour" bigint, "avg_speed" numeric, "health_score" integer, "checked_by_default" boolean)
    LANGUAGE "sql" STABLE
    AS $$
  SELECT 
    m.source,
    m.source as name,
    true as is_active,
    true as is_functional,
    now() as derniere_activite,
    now() as last_seen,
    now() as last_update,
    count(*) as total_produits,
    count(*) as product_count,
    count(*) as total_products,
    0::bigint, 0::bigint, 0::bigint, 0::bigint, 0::bigint,
    0::numeric as avg_speed,
    100 as health_score,
    true as checked_by_default
  FROM public.mv_products_unit_price m
  GROUP BY m.source
  ORDER BY m.source;
$$;


ALTER FUNCTION "public"."get_scraper_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_scraper_statut"() RETURNS TABLE("source" "text", "total_produits" bigint, "derniere_activite" timestamp with time zone, "nouveaux_1h" bigint, "modifies_1h" bigint, "checked_by_default" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "statement_timeout" TO '30s'
    AS $$
with ss as (
  select
    s.source,
    coalesce(s.total_produits,0)::bigint as total_produits,
    s.derniere_activite,
    coalesce(s.nouveaux_1h,0)::bigint as nouveaux_1h,
    coalesce(s.modifies_1h,0)::bigint as modifies_1h
  from public.scraper_status s
  where s.source is not null and btrim(s.source) <> ''
),
mv as (
  select
    p.source,
    count(*)::bigint as total_produits
  from public.mv_products_current p
  where p.source is not null and btrim(p.source) <> ''
  group by p.source
),
live as (
  select
    p.source,
    max(p.updated_at) as derniere_activite
  from public.products p
  where p.source is not null and btrim(p.source) <> ''
  group by p.source
),
sources as (
  select source from ss
  union
  select source from mv
  union
  select source from live
)
select
  s.source,
  coalesce(ss.total_produits, mv.total_produits, 0::bigint) as total_produits,
  case
    when ss.derniere_activite is null then live.derniere_activite
    when live.derniere_activite is null then ss.derniere_activite
    else greatest(ss.derniere_activite, live.derniere_activite)
  end as derniere_activite,
  coalesce(ss.nouveaux_1h, 0::bigint) as nouveaux_1h,
  coalesce(ss.modifies_1h, 0::bigint) as modifies_1h,
  (lower(s.source) not in ('manomano.fr', 'manomano.de', 'manomano_fr', 'manomano_de')) as checked_by_default
from sources s
left join ss on ss.source = s.source
left join mv on mv.source = s.source
left join live on live.source = s.source
order by s.source;
$$;


ALTER FUNCTION "public"."get_scraper_statut"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_scraping_activity_chart"("days_back" integer DEFAULT 14) RETURNS TABLE("day" "date", "bauhaus" bigint, "gotools" bigint, "voelkner" bigint, "lefeld" bigint, "geizhals" bigint)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM mv_scraping_activity_14d
    ORDER BY day ASC;
END;
$$;


ALTER FUNCTION "public"."get_scraping_activity_chart"("days_back" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_top_deals"("min_savings_pct" numeric DEFAULT 20, "max_results" integer DEFAULT 100) RETURNS TABLE("ean" "text", "name" "text", "brand" "text", "nb_sources" bigint, "nb_products" bigint, "sources" "text", "prix_min" numeric, "prix_max" numeric, "economie_pct" numeric, "economie_eur" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.ean::TEXT,
    MIN(p.name)::TEXT as name,
    MIN(p.brand)::TEXT as brand,
    COUNT(DISTINCT p.source) as nb_sources,
    COUNT(*) as nb_products,
    STRING_AGG(DISTINCT p.source, ', ' ORDER BY p.source) as sources,
    MIN(p.price) as prix_min,
    MAX(p.price) as prix_max,
    ROUND(((MAX(p.price) - MIN(p.price)) / NULLIF(MAX(p.price), 0) * 100)::numeric, 2) as economie_pct,
    ROUND((MAX(p.price) - MIN(p.price))::numeric, 2) as economie_eur
  FROM public.v_products_full p
  WHERE p.ean IS NOT NULL
    AND p.ean <> ''
    AND p.price > 0
    AND p.in_stock = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.deals_ean_blacklist bl
      WHERE bl.ean = p.ean
    )
  GROUP BY p.ean
  HAVING COUNT(DISTINCT p.source) >= 2
    AND ((MAX(p.price) - MIN(p.price)) / NULLIF(MAX(p.price), 0) * 100) >= min_savings_pct
  ORDER BY economie_pct DESC
  LIMIT max_results;
END;
$$;


ALTER FUNCTION "public"."get_top_deals"("min_savings_pct" numeric, "max_results" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_scraping_run"("p_source" "text", "p_run_type" "text", "p_products_found" integer, "p_duration_seconds" integer DEFAULT 0) RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_log_id UUID;
BEGIN
  INSERT INTO scraping_logs (
    source,
    scrape_type,
    run_type,
    products_found,
    products_new,
    products_updated,
    duration_seconds,
    status,
    started_at,
    finished_at,
    metadata
  ) VALUES (
    p_source,
    p_run_type,                                    -- scrape_type (requis)
    p_run_type,                                    -- run_type (nouveau)
    p_products_found,
    CASE WHEN p_run_type IN ('full', 'catalog') THEN p_products_found ELSE 0 END,
    CASE WHEN p_run_type IN ('update', 'deals') THEN p_products_found ELSE 0 END,
    p_duration_seconds,
    'done',
    NOW() - (p_duration_seconds || ' seconds')::INTERVAL,  -- started_at rétro-calculé
    NOW(),                                                   -- finished_at
    jsonb_build_object(
      'source', p_source,
      'run_type', p_run_type,
      'timestamp', EXTRACT(EPOCH FROM NOW())
    )
  )
  RETURNING id INTO v_log_id;
  
  RETURN v_log_id;
END;
$$;


ALTER FUNCTION "public"."log_scraping_run"("p_source" "text", "p_run_type" "text", "p_products_found" integer, "p_duration_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_search_de"("p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    AS $$
  with s as (
    select lower(coalesce(p_text, '')) as t
  ), r as (
    select replace(replace(replace(replace(t, 'ß', 'ss'), 'ae', 'a'), 'oe', 'o'), 'ue', 'u') as t
    from s
  ), u as (
    select replace(replace(replace(t, 'ä', 'a'), 'ö', 'o'), 'ü', 'u') as t
    from r
  )
  select regexp_replace(t, '[^a-z0-9]+', ' ', 'g')
  from u;
$$;


ALTER FUNCTION "public"."normalize_search_de"("p_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_price_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.price IS DISTINCT FROM NEW.price) THEN
        INSERT INTO price_history(product_id, ean, source, price, recorded_at)
        VALUES (NEW.id, NEW.ean, NEW.source, NEW.price, NOW());
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."record_price_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_active_blitzangebote"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY v_active_blitzangebote;
END;
$$;


ALTER FUNCTION "public"."refresh_active_blitzangebote"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_deals_cache"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_products_current;
END;
$$;


ALTER FUNCTION "public"."refresh_deals_cache"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_mr_status"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Met à jour mr_weight_kg et mr_max_dim_cm pour tous les produits
    UPDATE products
    SET 
        mr_weight_kg  = extract_weight_kg(specs),
        mr_max_dim_cm = extract_max_dim_cm(specs)
    WHERE mr_weight_kg IS NULL OR mr_max_dim_cm IS NULL;

    -- Calcule mr_compatible selon les règles MR
    UPDATE products
    SET mr_compatible = 
        CASE
            WHEN mr_weight_kg IS NULL OR mr_max_dim_cm IS NULL THEN FALSE
            WHEN mr_weight_kg <= 25 AND mr_max_dim_cm <= 120 THEN TRUE
            ELSE FALSE
        END
    WHERE mr_compatible IS NULL OR mr_weight_kg IS NOT NULL;
END;
$$;


ALTER FUNCTION "public"."refresh_mr_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_mr_status"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE products SET
    mr_weight_kg  = COALESCE(weight_kg, extract_weight_kg(specs)),
    mr_max_dim_cm = extract_max_dim_cm(specs),
    mr_compatible = CASE
      WHEN COALESCE(weight_kg, extract_weight_kg(specs)) >= 25 THEN false
      WHEN extract_max_dim_cm(specs) >= 120                    THEN false
      WHEN COALESCE(weight_kg, extract_weight_kg(specs)) IS NOT NULL
        AND extract_max_dim_cm(specs) IS NOT NULL              THEN true
      ELSE NULL
    END
  WHERE id = p_id;
END;
$$;


ALTER FUNCTION "public"."refresh_mr_status"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_mv_best_deals_by_ean_safe"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_now_paris time;
  v_locked boolean;
begin
  v_now_paris := (now() at time zone 'Europe/Paris')::time;

  -- Fenêtre marché FR : 06:00 -> 23:00 (heure de Paris)
  if not (v_now_paris >= time '06:00' and v_now_paris < time '23:00') then
    return;
  end if;

  -- Évite le chevauchement si un run est encore en cours
  v_locked := pg_try_advisory_lock(hashtext('mv_best_deals_by_ean_refresh_lock'));
  if not v_locked then
    return;
  end if;

  begin
    perform set_config('statement_timeout', '0', true);
    refresh materialized view concurrently public.mv_best_deals_by_ean;
  exception when others then
    perform pg_advisory_unlock(hashtext('mv_best_deals_by_ean_refresh_lock'));
    raise;
  end;

  perform pg_advisory_unlock(hashtext('mv_best_deals_by_ean_refresh_lock'));
end;
$$;


ALTER FUNCTION "public"."refresh_mv_best_deals_by_ean_safe"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_mv_deals_by_ean"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
declare
  v_relkind_deals "char";
  v_relkind_safe  "char";
  v_locked boolean;
begin
  v_locked := pg_try_advisory_lock(hashtext('refresh_mv_deals_by_ean_lock'));
  if not v_locked then
    return;
  end if;

  begin
    select c.relkind into v_relkind_deals
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'mv_deals_by_ean'
    limit 1;

    select c.relkind into v_relkind_safe
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'mv_deals_by_ean_safe'
    limit 1;

    perform set_config('statement_timeout', '0', true);

    if v_relkind_deals = 'm' then
      execute 'refresh materialized view concurrently public.mv_deals_by_ean';
    end if;

    if v_relkind_safe = 'm' then
      execute 'refresh materialized view concurrently public.mv_deals_by_ean_safe';
    end if;

  exception when others then
    perform pg_advisory_unlock(hashtext('refresh_mv_deals_by_ean_lock'));
    raise;
  end;

  perform pg_advisory_unlock(hashtext('refresh_mv_deals_by_ean_lock'));
end;
$$;


ALTER FUNCTION "public"."refresh_mv_deals_by_ean"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_mv_products"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Augmente le timeout pour cette session
  PERFORM set_config('statement_timeout', '600000', false); -- 10 minutes en millisecondes
  
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_products_current;
END;
$$;


ALTER FUNCTION "public"."refresh_mv_products"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_mv_products_unit_price"() RETURNS "void"
    LANGUAGE "sql"
    AS $$
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_products_unit_price;
$$;


ALTER FUNCTION "public"."refresh_mv_products_unit_price"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_deals_ean_blacklist"("p_ean" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  delete from public.deals_ean_blacklist
  where ean = trim(coalesce(p_ean,''));
$$;


ALTER FUNCTION "public"."remove_deals_ean_blacklist"("p_ean" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_ean_from_mpn"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_ean text;
begin
  -- Seulement si pas d'EAN mais un MPN
  if (NEW.ean IS NULL OR NEW.ean = '') AND NEW.mpn IS NOT NULL AND NEW.mpn <> '' then
    -- Chercher un EAN chez un autre fournisseur avec le même MPN
    SELECT p.ean INTO v_ean
    FROM public.products p
    WHERE p.mpn = NEW.mpn
      AND p.ean IS NOT NULL AND p.ean <> ''
      AND p.id <> NEW.id
    LIMIT 1;
    
    IF v_ean IS NOT NULL THEN
      NEW.ean := v_ean;
    END IF;
  end if;
  RETURN NEW;
end;
$$;


ALTER FUNCTION "public"."resolve_ean_from_mpn"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_ean_from_mpn_batch"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.products p
  SET ean = (
    SELECT p2.ean FROM public.products p2
    WHERE p2.mpn = p.mpn
      AND p2.ean IS NOT NULL AND p2.ean <> ''
      AND p2.id <> p.id
    LIMIT 1
  )
  WHERE p.id IN (
    SELECT p3.id FROM public.products p3
    WHERE (p3.ean IS NULL OR p3.ean = '')
      AND p3.mpn IS NOT NULL AND p3.mpn <> ''
      AND EXISTS (
        SELECT 1 FROM public.products p4
        WHERE p4.mpn = p3.mpn
          AND p4.ean IS NOT NULL AND p4.ean <> ''
          AND p4.id <> p3.id
      )
    LIMIT 500
  );
END;
$$;


ALTER FUNCTION "public"."resolve_ean_from_mpn_batch"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_products_smart"("search_term" "text", "in_stock_only" boolean DEFAULT false, "limit_results" integer DEFAULT 100) RETURNS TABLE("id" "uuid", "name" "text", "ean" "text", "price" numeric, "source" "text", "image_url" "text", "in_stock" boolean, "brand" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.id,
    p.name::TEXT,
    p.ean::TEXT,
    p.price,
    p.source::TEXT,
    p.image_url_fixed::TEXT,
    p.in_stock,
    p.brand::TEXT
  FROM v_products_full p
  WHERE p.name ILIKE '%' || search_term || '%'
    AND (NOT in_stock_only OR p.in_stock = true)
    AND p.price > 0
  ORDER BY 
    -- Priorité : nom commence par le terme recherché
    CASE WHEN p.name ILIKE search_term || '%' THEN 1 ELSE 2 END,
    -- Puis par prix croissant
    p.price ASC
  LIMIT limit_results;
END;
$$;


ALTER FUNCTION "public"."search_products_smart"("search_term" "text", "in_stock_only" boolean, "limit_results" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_technikdirekt_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_technikdirekt_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_any_scraper_product_to_products"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  j jsonb := to_jsonb(new);
  v_source text := lower(coalesce(nullif(j->>'source',''), replace(tg_table_name, '_products', '')));
  v_price numeric;
  v_brand text;
  v_pack_quantity integer;
begin
  if coalesce(j->>'ean','') = '' then
    return new;
  end if;

  begin
    v_price := nullif(regexp_replace(coalesce(j->>'price',''), '[^0-9\.,-]+', '', 'g'), '')::numeric;
  exception when others then
    v_price := null;
  end;

  begin
    v_pack_quantity := nullif(j->>'pack_quantity','')::integer;
  exception when others then
    v_pack_quantity := null;
  end;

  v_brand := coalesce(nullif(j->>'brand',''), nullif(j->>'brand_name',''));

  insert into public.products (
    ean, name, brand, brand_name, price, product_url, image_url,
    category, subcategory, description, source, pack_quantity, updated_at
  ) values (
    nullif(j->>'ean',''),
    nullif(j->>'name',''),
    v_brand,
    v_brand,
    v_price,
    nullif(j->>'product_url',''),
    nullif(j->>'image_url',''),
    nullif(j->>'category',''),
    nullif(j->>'subcategory',''),
    nullif(j->>'description',''),
    v_source,
    v_pack_quantity,
    now()
  )
  on conflict (source, product_url) where product_url is not null
  do update set
    ean = excluded.ean,
    name = coalesce(excluded.name, public.products.name),
    brand = coalesce(excluded.brand, public.products.brand),
    brand_name = coalesce(excluded.brand_name, public.products.brand_name),
    price = coalesce(excluded.price, public.products.price),
    image_url = coalesce(excluded.image_url, public.products.image_url),
    category = coalesce(excluded.category, public.products.category),
    subcategory = coalesce(excluded.subcategory, public.products.subcategory),
    description = coalesce(excluded.description, public.products.description),
    pack_quantity = coalesce(excluded.pack_quantity, public.products.pack_quantity),
    updated_at = now();

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_any_scraper_product_to_products"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_products_to_translate"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.name_fr IS NULL AND NEW.name IS NOT NULL AND NEW.ean IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM public.multi_source_eans WHERE ean = NEW.ean) THEN
      INSERT INTO public.products_to_translate(id, name, specs, category_path, description, source, ean)
      VALUES (NEW.id, NEW.name, NEW.specs, NEW.category_path, NEW.description, NEW.source, NEW.ean)
      ON CONFLICT (id) DO NOTHING;
    END IF;
  END IF;
  IF NEW.name_fr IS NOT NULL THEN
    DELETE FROM public.products_to_translate WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_products_to_translate"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_scraper_status"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE scraper_status ss
  SET 
    derniere_activite = subq.last_activity,
    total_produits = subq.total,
    updated_at = NOW()
  FROM (
    SELECT 
      source, 
      MAX(updated_at) as last_activity,
      COUNT(*) as total
    FROM products
    GROUP BY source
  ) subq
  WHERE ss.source = subq.source;
END;
$$;


ALTER FUNCTION "public"."sync_scraper_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_is_top_deal"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE products 
    SET is_top_deal = true
    WHERE id::text = NEW.product_id
    AND price >= 10;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_is_top_deal"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;


ALTER FUNCTION "public"."update_updated_at"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."account_holder" (
    "id" "text" NOT NULL,
    "provider_id" "text" NOT NULL,
    "external_id" "text" NOT NULL,
    "email" "text",
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."account_holder" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."api_key" (
    "id" "text" NOT NULL,
    "token" "text" NOT NULL,
    "salt" "text" NOT NULL,
    "redacted" "text" NOT NULL,
    "title" "text" NOT NULL,
    "type" "text" NOT NULL,
    "last_used_at" timestamp with time zone,
    "created_by" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_by" "text",
    "revoked_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "api_key_type_check" CHECK (("type" = ANY (ARRAY['publishable'::"text", 'secret'::"text"])))
);


ALTER TABLE "public"."api_key" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."application_method_buy_rules" (
    "application_method_id" "text" NOT NULL,
    "promotion_rule_id" "text" NOT NULL
);


ALTER TABLE "public"."application_method_buy_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."application_method_target_rules" (
    "application_method_id" "text" NOT NULL,
    "promotion_rule_id" "text" NOT NULL
);


ALTER TABLE "public"."application_method_target_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."auth_identity" (
    "id" "text" NOT NULL,
    "app_metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."auth_identity" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bauportal_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text",
    "brand" "text",
    "sku" "text",
    "ean" "text",
    "price" numeric,
    "price_original" numeric,
    "price_unit" "text",
    "currency" "text" DEFAULT 'EUR'::"text",
    "availability" "text",
    "delivery_info" "text",
    "category" "text",
    "subcategory" "text",
    "description" "text",
    "image_url" "text",
    "image_urls" "jsonb",
    "product_url" "text" NOT NULL,
    "rating" numeric,
    "review_count" integer,
    "specifications" "jsonb",
    "weight" "text",
    "dimensions" "text",
    "scraped_at" timestamp with time zone,
    "source" "text" DEFAULT 'bauportal24h'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "variant_groups" "text",
    "selected_variant_options" "text",
    "variant_switch_url" "text",
    "is_variant" boolean,
    "parent_url" "text",
    "variant_label" "text",
    "variant_group" "text",
    "variant_value" "text",
    "all_variants" "text",
    "pack_quantity" integer DEFAULT 1
);


ALTER TABLE "public"."bauportal_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."brand_blacklist" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "brand" "text" NOT NULL,
    "reason" "text",
    "active" boolean DEFAULT true
);


ALTER TABLE "public"."brand_blacklist" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."capture" (
    "id" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "payment_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "created_by" "text",
    "metadata" "jsonb"
);


ALTER TABLE "public"."capture" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart" (
    "id" "text" NOT NULL,
    "region_id" "text",
    "customer_id" "text",
    "sales_channel_id" "text",
    "email" "text",
    "currency_code" "text" NOT NULL,
    "shipping_address_id" "text",
    "billing_address_id" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "locale" "text"
);


ALTER TABLE "public"."cart" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_address" (
    "id" "text" NOT NULL,
    "customer_id" "text",
    "company" "text",
    "first_name" "text",
    "last_name" "text",
    "address_1" "text",
    "address_2" "text",
    "city" "text",
    "country_code" "text",
    "province" "text",
    "postal_code" "text",
    "phone" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."cart_address" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_line_item" (
    "id" "text" NOT NULL,
    "cart_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "subtitle" "text",
    "thumbnail" "text",
    "quantity" integer NOT NULL,
    "variant_id" "text",
    "product_id" "text",
    "product_title" "text",
    "product_description" "text",
    "product_subtitle" "text",
    "product_type" "text",
    "product_collection" "text",
    "product_handle" "text",
    "variant_sku" "text",
    "variant_barcode" "text",
    "variant_title" "text",
    "variant_option_values" "jsonb",
    "requires_shipping" boolean DEFAULT true NOT NULL,
    "is_discountable" boolean DEFAULT true NOT NULL,
    "is_tax_inclusive" boolean DEFAULT false NOT NULL,
    "compare_at_unit_price" numeric,
    "raw_compare_at_unit_price" "jsonb",
    "unit_price" numeric NOT NULL,
    "raw_unit_price" "jsonb" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "product_type_id" "text",
    "is_custom_price" boolean DEFAULT false NOT NULL,
    "is_giftcard" boolean DEFAULT false NOT NULL,
    CONSTRAINT "cart_line_item_unit_price_check" CHECK (("unit_price" >= (0)::numeric))
);


ALTER TABLE "public"."cart_line_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_line_item_adjustment" (
    "id" "text" NOT NULL,
    "description" "text",
    "promotion_id" "text",
    "code" "text",
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "provider_id" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "item_id" "text",
    "is_tax_inclusive" boolean DEFAULT false NOT NULL,
    CONSTRAINT "cart_line_item_adjustment_check" CHECK (("amount" >= (0)::numeric))
);


ALTER TABLE "public"."cart_line_item_adjustment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_line_item_tax_line" (
    "id" "text" NOT NULL,
    "description" "text",
    "tax_rate_id" "text",
    "code" "text" NOT NULL,
    "rate" real NOT NULL,
    "provider_id" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "item_id" "text"
);


ALTER TABLE "public"."cart_line_item_tax_line" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_payment_collection" (
    "cart_id" character varying(255) NOT NULL,
    "payment_collection_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."cart_payment_collection" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_promotion" (
    "cart_id" character varying(255) NOT NULL,
    "promotion_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."cart_promotion" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_shipping_method" (
    "id" "text" NOT NULL,
    "cart_id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "jsonb",
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "is_tax_inclusive" boolean DEFAULT false NOT NULL,
    "shipping_option_id" "text",
    "data" "jsonb",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "cart_shipping_method_check" CHECK (("amount" >= (0)::numeric))
);


ALTER TABLE "public"."cart_shipping_method" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_shipping_method_adjustment" (
    "id" "text" NOT NULL,
    "description" "text",
    "promotion_id" "text",
    "code" "text",
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "provider_id" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "shipping_method_id" "text"
);


ALTER TABLE "public"."cart_shipping_method_adjustment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_shipping_method_tax_line" (
    "id" "text" NOT NULL,
    "description" "text",
    "tax_rate_id" "text",
    "code" "text" NOT NULL,
    "rate" real NOT NULL,
    "provider_id" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "shipping_method_id" "text"
);


ALTER TABLE "public"."cart_shipping_method_tax_line" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."contorion_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text",
    "brand" "text",
    "sku" "text",
    "ean" "text",
    "price" numeric,
    "price_original" numeric,
    "currency" "text" DEFAULT 'EUR'::"text",
    "availability" "text",
    "category" "text",
    "subcategory" "text",
    "description" "text",
    "image_url" "text",
    "product_url" "text" NOT NULL,
    "rating" numeric,
    "review_count" integer,
    "specifications" "jsonb",
    "scraped_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source" "text" DEFAULT 'contorion'::"text" NOT NULL,
    "variant_groups" "text",
    "manufacturer" "text",
    "manufacturer_sku" "text",
    "delivery_info" "text",
    "image_urls" "text",
    "weight" "text",
    "dimensions" "text",
    "pack_quantity" integer DEFAULT 1
);


ALTER TABLE "public"."contorion_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_line" (
    "id" "text" NOT NULL,
    "cart_id" "text" NOT NULL,
    "reference" "text",
    "reference_id" "text",
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."credit_line" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."currency" (
    "code" "text" NOT NULL,
    "symbol" "text" NOT NULL,
    "symbol_native" "text" NOT NULL,
    "decimal_digits" integer DEFAULT 0 NOT NULL,
    "rounding" numeric DEFAULT 0 NOT NULL,
    "raw_rounding" "jsonb" NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."currency" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer" (
    "id" "text" NOT NULL,
    "company_name" "text",
    "first_name" "text",
    "last_name" "text",
    "email" "text",
    "phone" "text",
    "has_account" boolean DEFAULT false NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "created_by" "text"
);


ALTER TABLE "public"."customer" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_account_holder" (
    "customer_id" character varying(255) NOT NULL,
    "account_holder_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."customer_account_holder" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_address" (
    "id" "text" NOT NULL,
    "customer_id" "text" NOT NULL,
    "address_name" "text",
    "is_default_shipping" boolean DEFAULT false NOT NULL,
    "is_default_billing" boolean DEFAULT false NOT NULL,
    "company" "text",
    "first_name" "text",
    "last_name" "text",
    "address_1" "text",
    "address_2" "text",
    "city" "text",
    "country_code" "text",
    "province" "text",
    "postal_code" "text",
    "phone" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."customer_address" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_group" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "metadata" "jsonb",
    "created_by" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."customer_group" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_group_customer" (
    "id" "text" NOT NULL,
    "customer_id" "text" NOT NULL,
    "customer_group_id" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "text",
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."customer_group_customer" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."deals_ean_blacklist" (
    "ean" "text" NOT NULL,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."deals_ean_blacklist" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "geizhals_id" "text",
    "name" "text" NOT NULL,
    "category" "text",
    "subcategory" "text",
    "image_url" "text",
    "product_url" "text",
    "ean" "text",
    "is_brand_flagged" boolean DEFAULT false,
    "brand_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "weight_kg" numeric(8,3),
    "dimensions" "text",
    "enriched_at" timestamp with time zone,
    "subsubcategory" "text",
    "mpn" "text",
    "specs" "jsonb",
    "images_all" "jsonb",
    "variants" "jsonb",
    "source" "text" DEFAULT 'geizhals'::"text",
    "lefeld_id" character varying(100),
    "lefeld_article_id" character varying(100),
    "amazon_asin" character varying(100),
    "ebay_item_id" character varying(100),
    "idealo_id" character varying(100),
    "is_occasion" boolean DEFAULT false,
    "bauhaus_id" character varying(20),
    "category_path" "text"[],
    "comparable_products" "text"[],
    "recommended_products" "text"[],
    "name_fr" "text",
    "category_path_fr" "text"[],
    "specs_fr" "jsonb",
    "translated_at" timestamp with time zone,
    "variant_group_id" "text",
    "datasheets" "text"[],
    "variants_fr" "jsonb",
    "datasheets_r2" "text"[],
    "datasheets_fr_r2" "text"[],
    "mr_compatible" boolean DEFAULT false,
    "mr_weight_kg" numeric,
    "mr_max_dim_cm" numeric,
    "gotools_id" character varying(20),
    "voelkner_id" character varying(20),
    "is_sale" boolean DEFAULT false,
    "is_blitzangebot" boolean DEFAULT false,
    "is_refurbished" boolean DEFAULT false,
    "deal_end_timestamp" bigint,
    "deal_end_date" timestamp with time zone,
    "deal_time_remaining" "jsonb",
    "brand" "text",
    "in_stock" boolean DEFAULT true,
    "url" "text",
    "price" numeric,
    "manufacturer_ref" "text",
    "last_scraped" timestamp with time zone DEFAULT "now"(),
    "embedding" "public"."vector"(1536),
    "manomano_id" character varying(20),
    "manomano_model_id" character varying(20),
    "country_code" character(2),
    "description" "text",
    "contorion_id" character varying,
    "alternate_id" character varying,
    "online_stock" integer,
    "delivery_time" "text",
    "is_free_shipping" boolean,
    "short_description" "text",
    "pack_quantity" integer DEFAULT 1,
    "image_r2_url" "text",
    "image_r2_at" timestamp with time zone,
    "description_fr" "text",
    "is_top_deal" boolean DEFAULT false,
    "medusa_id" "text"
);


ALTER TABLE "public"."products" OWNER TO "postgres";


COMMENT ON COLUMN "public"."products"."datasheets_r2" IS 'URLs des fiches techniques allemandes originales sur R2';



COMMENT ON COLUMN "public"."products"."datasheets_fr_r2" IS 'URLs des fiches techniques traduites en français sur R2';



COMMENT ON COLUMN "public"."products"."is_sale" IS 'Promotion en cours (% SALE)';



COMMENT ON COLUMN "public"."products"."is_blitzangebot" IS 'Deal flash Voelkner (affichage homepage prioritaire)';



COMMENT ON COLUMN "public"."products"."is_refurbished" IS 'Produit reconditionné (catégorie séparée sur le site)';



COMMENT ON COLUMN "public"."products"."deal_end_timestamp" IS 'Unix timestamp de fin du Blitzangebot (data-time du countdown)';



COMMENT ON COLUMN "public"."products"."deal_end_date" IS 'Date ISO de fin du deal (conversion depuis deal_end_timestamp)';



COMMENT ON COLUMN "public"."products"."deal_time_remaining" IS 'JSON {days, hours, minutes, seconds, total_seconds} au moment du scraping';



CREATE OR REPLACE VIEW "public"."deals_eligible_products" AS
 WITH "extracted" AS (
         SELECT "p_1"."id",
            "max"(("replace"("m"."m"[1], ','::"text", '.'::"text"))::numeric) AS "extracted_weight_kg"
           FROM ("public"."products" "p_1"
             CROSS JOIN LATERAL "regexp_matches"(((COALESCE("p_1"."description", ''::"text") || '
'::"text") || COALESCE(("p_1"."specs")::"text", ''::"text")), '(?is)(?:gewicht|poids|weight)\s*[:\-]?\s*([0-9]+(?:[\.,][0-9]+)?)\s*kg'::"text", 'g'::"text") "m"("m"))
          GROUP BY "p_1"."id"
        )
 SELECT "p"."id",
    "p"."geizhals_id",
    "p"."name",
    "p"."category",
    "p"."subcategory",
    "p"."image_url",
    "p"."product_url",
    "p"."ean",
    "p"."is_brand_flagged",
    "p"."brand_name",
    "p"."created_at",
    "p"."updated_at",
    "p"."weight_kg",
    "p"."dimensions",
    "p"."enriched_at",
    "p"."subsubcategory",
    "p"."mpn",
    "p"."specs",
    "p"."images_all",
    "p"."variants",
    "p"."source",
    "p"."lefeld_id",
    "p"."lefeld_article_id",
    "p"."amazon_asin",
    "p"."ebay_item_id",
    "p"."idealo_id",
    "p"."is_occasion",
    "p"."bauhaus_id",
    "p"."category_path",
    "p"."comparable_products",
    "p"."recommended_products",
    "p"."name_fr",
    "p"."category_path_fr",
    "p"."specs_fr",
    "p"."translated_at",
    "p"."variant_group_id",
    "p"."datasheets",
    "p"."variants_fr",
    "p"."datasheets_r2",
    "p"."datasheets_fr_r2",
    "p"."mr_compatible",
    "p"."mr_weight_kg",
    "p"."mr_max_dim_cm",
    "p"."gotools_id",
    "p"."voelkner_id",
    "p"."is_sale",
    "p"."is_blitzangebot",
    "p"."is_refurbished",
    "p"."deal_end_timestamp",
    "p"."deal_end_date",
    "p"."deal_time_remaining",
    "p"."brand",
    "p"."in_stock",
    "p"."url",
    "p"."price",
    "p"."manufacturer_ref",
    "p"."last_scraped",
    "p"."embedding",
    "p"."manomano_id",
    "p"."manomano_model_id",
    "p"."country_code",
    "p"."description",
    "p"."contorion_id",
    "p"."alternate_id",
    "p"."online_stock",
    "p"."delivery_time",
    "p"."is_free_shipping",
    COALESCE("p"."weight_kg", "e"."extracted_weight_kg") AS "effective_weight_kg"
   FROM ("public"."products" "p"
     LEFT JOIN "extracted" "e" ON (("e"."id" = "p"."id")))
  WHERE (("p"."ean" IS NOT NULL) AND ("btrim"("p"."ean") <> ''::"text") AND ("p"."image_url" IS NOT NULL) AND ((COALESCE("p"."weight_kg", "e"."extracted_weight_kg") IS NULL) OR (COALESCE("p"."weight_kg", "e"."extracted_weight_kg") < (25)::numeric)) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."deals_ean_blacklist" "b"
          WHERE ("b"."ean" = "p"."ean")))));


ALTER VIEW "public"."deals_eligible_products" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."deals_eligible_werkzeug_guenstig" AS
 WITH "extracted" AS (
         SELECT "p_1"."id",
            "max"(("replace"("m"."m"[1], ','::"text", '.'::"text"))::numeric) AS "extracted_weight_kg"
           FROM ("public"."products" "p_1"
             CROSS JOIN LATERAL "regexp_matches"(((COALESCE("p_1"."description", ''::"text") || '
'::"text") || COALESCE(("p_1"."specs")::"text", ''::"text")), '(?is)(?:gewicht|poids|weight)\s*[:\-]?\s*([0-9]+(?:[\.,][0-9]+)?)\s*kg'::"text", 'g'::"text") "m"("m"))
          WHERE ("lower"("p_1"."source") = 'werkzeug_guenstig'::"text")
          GROUP BY "p_1"."id"
        )
 SELECT "p"."id",
    "p"."geizhals_id",
    "p"."name",
    "p"."category",
    "p"."subcategory",
    "p"."image_url",
    "p"."product_url",
    "p"."ean",
    "p"."is_brand_flagged",
    "p"."brand_name",
    "p"."created_at",
    "p"."updated_at",
    "p"."weight_kg",
    "p"."dimensions",
    "p"."enriched_at",
    "p"."subsubcategory",
    "p"."mpn",
    "p"."specs",
    "p"."images_all",
    "p"."variants",
    "p"."source",
    "p"."lefeld_id",
    "p"."lefeld_article_id",
    "p"."amazon_asin",
    "p"."ebay_item_id",
    "p"."idealo_id",
    "p"."is_occasion",
    "p"."bauhaus_id",
    "p"."category_path",
    "p"."comparable_products",
    "p"."recommended_products",
    "p"."name_fr",
    "p"."category_path_fr",
    "p"."specs_fr",
    "p"."translated_at",
    "p"."variant_group_id",
    "p"."datasheets",
    "p"."variants_fr",
    "p"."datasheets_r2",
    "p"."datasheets_fr_r2",
    "p"."mr_compatible",
    "p"."mr_weight_kg",
    "p"."mr_max_dim_cm",
    "p"."gotools_id",
    "p"."voelkner_id",
    "p"."is_sale",
    "p"."is_blitzangebot",
    "p"."is_refurbished",
    "p"."deal_end_timestamp",
    "p"."deal_end_date",
    "p"."deal_time_remaining",
    "p"."brand",
    "p"."in_stock",
    "p"."url",
    "p"."price",
    "p"."manufacturer_ref",
    "p"."last_scraped",
    "p"."embedding",
    "p"."manomano_id",
    "p"."manomano_model_id",
    "p"."country_code",
    "p"."description",
    "p"."contorion_id",
    "p"."alternate_id",
    "p"."online_stock",
    "p"."delivery_time",
    "p"."is_free_shipping",
    COALESCE("p"."weight_kg", "e"."extracted_weight_kg") AS "effective_weight_kg"
   FROM ("public"."products" "p"
     LEFT JOIN "extracted" "e" ON (("e"."id" = "p"."id")))
  WHERE (("lower"("p"."source") = 'werkzeug_guenstig'::"text") AND ("p"."ean" IS NOT NULL) AND ("btrim"("p"."ean") <> ''::"text") AND ("p"."image_url" IS NOT NULL) AND ((COALESCE("p"."weight_kg", "e"."extracted_weight_kg") IS NULL) OR (COALESCE("p"."weight_kg", "e"."extracted_weight_kg") < (25)::numeric)) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."deals_ean_blacklist" "b"
          WHERE ("b"."ean" = "p"."ean")))));


ALTER VIEW "public"."deals_eligible_werkzeug_guenstig" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fr_price_comparisons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid",
    "fr_price" numeric(10,2),
    "fr_source" "text",
    "fr_url" "text",
    "your_price" numeric(10,2),
    "shipping_cost" numeric(5,2) DEFAULT 4.00,
    "margin_euros" numeric(10,2),
    "margin_percent" numeric(5,2),
    "checked_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."fr_price_comparisons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fulfillment" (
    "id" "text" NOT NULL,
    "location_id" "text" NOT NULL,
    "packed_at" timestamp with time zone,
    "shipped_at" timestamp with time zone,
    "delivered_at" timestamp with time zone,
    "canceled_at" timestamp with time zone,
    "data" "jsonb",
    "provider_id" "text",
    "shipping_option_id" "text",
    "metadata" "jsonb",
    "delivery_address_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "marked_shipped_by" "text",
    "created_by" "text",
    "requires_shipping" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."fulfillment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fulfillment_address" (
    "id" "text" NOT NULL,
    "company" "text",
    "first_name" "text",
    "last_name" "text",
    "address_1" "text",
    "address_2" "text",
    "city" "text",
    "country_code" "text",
    "province" "text",
    "postal_code" "text",
    "phone" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."fulfillment_address" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fulfillment_item" (
    "id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "sku" "text" NOT NULL,
    "barcode" "text" NOT NULL,
    "quantity" numeric NOT NULL,
    "raw_quantity" "jsonb" NOT NULL,
    "line_item_id" "text",
    "inventory_item_id" "text",
    "fulfillment_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."fulfillment_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fulfillment_label" (
    "id" "text" NOT NULL,
    "tracking_number" "text" NOT NULL,
    "tracking_url" "text" NOT NULL,
    "label_url" "text" NOT NULL,
    "fulfillment_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."fulfillment_label" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fulfillment_provider" (
    "id" "text" NOT NULL,
    "is_enabled" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."fulfillment_provider" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fulfillment_set" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."fulfillment_set" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."geo_zone" (
    "id" "text" NOT NULL,
    "type" "text" DEFAULT 'country'::"text" NOT NULL,
    "country_code" "text" NOT NULL,
    "province_code" "text",
    "city" "text",
    "service_zone_id" "text" NOT NULL,
    "postal_expression" "jsonb",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "geo_zone_type_check" CHECK (("type" = ANY (ARRAY['country'::"text", 'province'::"text", 'city'::"text", 'zip'::"text"])))
);


ALTER TABLE "public"."geo_zone" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hardware_online_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source" "text" DEFAULT 'hardware_online'::"text",
    "sku" "text" NOT NULL,
    "name" "text",
    "description" "text",
    "brand" "text",
    "price" numeric,
    "image_url" "text",
    "images_all" "jsonb",
    "product_url" "text",
    "category" "text",
    "grade" "text",
    "grade_description" "text",
    "keyboard_layout" "text",
    "specs" "jsonb",
    "in_stock" boolean DEFAULT true,
    "delivery_time" "text",
    "is_refurbished" boolean DEFAULT true,
    "country_code" "text" DEFAULT 'DE'::"text",
    "last_scraped" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_promo" boolean DEFAULT false
);


ALTER TABLE "public"."hardware_online_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."image" (
    "id" "text" NOT NULL,
    "url" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "rank" integer DEFAULT 0 NOT NULL,
    "product_id" "text" NOT NULL
);


ALTER TABLE "public"."image" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_item" (
    "id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "sku" "text",
    "origin_country" "text",
    "hs_code" "text",
    "mid_code" "text",
    "material" "text",
    "weight" integer,
    "length" integer,
    "height" integer,
    "width" integer,
    "requires_shipping" boolean DEFAULT true NOT NULL,
    "description" "text",
    "title" "text",
    "thumbnail" "text",
    "metadata" "jsonb"
);


ALTER TABLE "public"."inventory_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_level" (
    "id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "inventory_item_id" "text" NOT NULL,
    "location_id" "text" NOT NULL,
    "stocked_quantity" numeric DEFAULT 0 NOT NULL,
    "reserved_quantity" numeric DEFAULT 0 NOT NULL,
    "incoming_quantity" numeric DEFAULT 0 NOT NULL,
    "metadata" "jsonb",
    "raw_stocked_quantity" "jsonb",
    "raw_reserved_quantity" "jsonb",
    "raw_incoming_quantity" "jsonb"
);


ALTER TABLE "public"."inventory_level" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invite" (
    "id" "text" NOT NULL,
    "email" "text" NOT NULL,
    "accepted" boolean DEFAULT false NOT NULL,
    "token" "text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."invite" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invite_rbac_role" (
    "invite_id" character varying(255) NOT NULL,
    "rbac_role_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."invite_rbac_role" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."link_module_migrations" (
    "id" integer NOT NULL,
    "table_name" character varying(255) NOT NULL,
    "link_descriptor" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."link_module_migrations" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."link_module_migrations_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."link_module_migrations_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."link_module_migrations_id_seq" OWNED BY "public"."link_module_migrations"."id";



CREATE TABLE IF NOT EXISTS "public"."location_fulfillment_provider" (
    "stock_location_id" character varying(255) NOT NULL,
    "fulfillment_provider_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."location_fulfillment_provider" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."location_fulfillment_set" (
    "stock_location_id" character varying(255) NOT NULL,
    "fulfillment_set_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."location_fulfillment_set" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mikro_orm_migrations" (
    "id" integer NOT NULL,
    "name" character varying(255),
    "executed_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."mikro_orm_migrations" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."mikro_orm_migrations_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."mikro_orm_migrations_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."mikro_orm_migrations_id_seq" OWNED BY "public"."mikro_orm_migrations"."id";



CREATE TABLE IF NOT EXISTS "public"."mr_keyword_blacklist" (
    "keyword" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."mr_keyword_blacklist" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."multi_source_eans" (
    "ean" "text",
    "source_count" bigint
);


ALTER TABLE "public"."multi_source_eans" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."mv_bauhaus_blacklist_eans" AS
 SELECT DISTINCT "ean"
   FROM "public"."products" "p"
  WHERE (("source" = 'bauhaus'::"text") AND ("mr_compatible" = false) AND ("ean" IS NOT NULL) AND ("ean" <> ''::"text"))
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."mv_bauhaus_blacklist_eans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_snapshots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid",
    "price_current" numeric(10,2) NOT NULL,
    "price_before" numeric(10,2),
    "drop_percent" numeric(5,2),
    "best_merchant" "text",
    "merchant_url" "text",
    "offers_count" integer,
    "in_stock" boolean DEFAULT true,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "shipping_de" numeric(6,2),
    "is_free_shipping" boolean DEFAULT false,
    "shipping_fr_estimated" numeric(6,2),
    "online_stock" integer,
    "delivery_time" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."price_snapshots" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."mv_best_deals_by_ean" AS
 WITH "latest_snapshots" AS (
         SELECT DISTINCT ON ("ps"."product_id") "ps"."product_id",
            "ps"."best_merchant",
            "ps"."price_current",
            "ps"."price_before",
            "ps"."drop_percent",
            "ps"."merchant_url",
            "ps"."scraped_at"
           FROM "public"."price_snapshots" "ps"
          ORDER BY "ps"."product_id", "ps"."scraped_at" DESC NULLS LAST
        ), "ranked" AS (
         SELECT "p"."ean",
            "p"."name" AS "title",
            COALESCE("p"."brand", "p"."brand_name") AS "brand",
            "ls"."best_merchant" AS "merchant",
            "ls"."price_current" AS "price",
            "ls"."price_before" AS "original_price",
            "ls"."drop_percent" AS "discount_pct",
            'EUR'::"text" AS "currency",
            COALESCE("ls"."merchant_url", "p"."url", "p"."product_url") AS "url",
            "p"."image_url",
            "ls"."scraped_at" AS "updated_at",
            "row_number"() OVER (PARTITION BY "p"."ean" ORDER BY "ls"."drop_percent" DESC NULLS LAST, "ls"."scraped_at" DESC NULLS LAST) AS "rn"
           FROM ("latest_snapshots" "ls"
             JOIN "public"."products" "p" ON (("p"."id" = "ls"."product_id")))
          WHERE ("p"."ean" IS NOT NULL)
        )
 SELECT "ean",
    "title",
    "brand",
    "merchant",
    "price",
    "original_price",
    "discount_pct",
    "currency",
    "url",
    "image_url",
    "updated_at"
   FROM "ranked"
  WHERE ("rn" = 1)
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."mv_best_deals_by_ean" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."mv_mr_eans" AS
 SELECT DISTINCT "ean"
   FROM "public"."products" "p"
  WHERE (("mr_compatible" IS TRUE) AND ("ean" IS NOT NULL) AND ("ean" <> ''::"text"))
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."mv_mr_eans" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."mv_mr_keyword_blacklist_hits" AS
 SELECT "p"."ean",
    "p"."source"
   FROM ("public"."products" "p"
     JOIN "public"."mr_keyword_blacklist" "k" ON ((("lower"("p"."name") ~~ (('%'::"text" || "lower"("k"."keyword")) || '%'::"text")) OR ("lower"("p"."category") ~~ (('%'::"text" || "lower"("k"."keyword")) || '%'::"text")))))
  WHERE (("p"."ean" IS NOT NULL) AND ("p"."ean" <> ''::"text"))
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."mv_mr_keyword_blacklist_hits" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."mv_products_current" AS
 SELECT "id",
    "name",
    "source",
    "product_url",
    "ean",
    "brand",
    "in_stock",
    "image_url",
    "created_at",
    "updated_at",
    COALESCE(( SELECT "ps"."price_current"
           FROM "public"."price_snapshots" "ps"
          WHERE ("ps"."product_id" = "p"."id")
          ORDER BY "ps"."scraped_at" DESC
         LIMIT 1), "price") AS "price"
   FROM "public"."products" "p";


ALTER VIEW "public"."mv_products_current" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."mv_products_unit_price" AS
 SELECT "p"."id",
    "p"."ean",
    "p"."source",
    "p"."product_url",
    "p"."price" AS "lot_price",
    GREATEST(1, COALESCE("pr"."pack_quantity", 1)) AS "pack_quantity",
    ("p"."price" / (GREATEST(1, COALESCE("pr"."pack_quantity", 1)))::numeric) AS "unit_price"
   FROM ("public"."mv_products_current" "p"
     JOIN "public"."products" "pr" ON (("pr"."id" = "p"."id")))
  WHERE (("p"."price" IS NOT NULL) AND ("p"."price" > (0)::numeric) AND ("p"."ean" IS NOT NULL) AND ("p"."ean" <> ''::"text") AND ("pr"."in_stock" = true) AND ("p"."source" <> ALL (ARRAY['manomano_fr'::"text", 'manomano_de'::"text"])))
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."mv_products_unit_price" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."mv_scraping_activity_14d" AS
 WITH "date_series" AS (
         SELECT ("generate_series"(((CURRENT_DATE - 13))::timestamp with time zone, (CURRENT_DATE)::timestamp with time zone, '1 day'::interval))::"date" AS "day"
        ), "unique_products_per_day" AS (
         SELECT DISTINCT "date"("ps"."scraped_at") AS "snapshot_day",
            "ps"."product_id",
            "p"."source"
           FROM ("public"."price_snapshots" "ps"
             JOIN "public"."products" "p" ON (("ps"."product_id" = "p"."id")))
          WHERE (("ps"."scraped_at" >= (CURRENT_DATE - 14)) AND ("ps"."scraped_at" < (CURRENT_DATE + 1)))
        ), "daily_counts" AS (
         SELECT "unique_products_per_day"."snapshot_day",
            "unique_products_per_day"."source",
            "count"(*) AS "product_count"
           FROM "unique_products_per_day"
          GROUP BY "unique_products_per_day"."snapshot_day", "unique_products_per_day"."source"
        )
 SELECT "ds"."day",
    (COALESCE("sum"("dc"."product_count") FILTER (WHERE ("dc"."source" = 'bauhaus'::"text")), (0)::numeric))::bigint AS "bauhaus",
    (COALESCE("sum"("dc"."product_count") FILTER (WHERE ("dc"."source" = 'gotools'::"text")), (0)::numeric))::bigint AS "gotools",
    (COALESCE("sum"("dc"."product_count") FILTER (WHERE ("dc"."source" = 'voelkner'::"text")), (0)::numeric))::bigint AS "voelkner",
    (COALESCE("sum"("dc"."product_count") FILTER (WHERE ("dc"."source" = 'lefeld'::"text")), (0)::numeric))::bigint AS "lefeld",
    (COALESCE("sum"("dc"."product_count") FILTER (WHERE ("dc"."source" = 'geizhals'::"text")), (0)::numeric))::bigint AS "geizhals"
   FROM ("date_series" "ds"
     LEFT JOIN "daily_counts" "dc" ON (("ds"."day" = "dc"."snapshot_day")))
  GROUP BY "ds"."day"
  ORDER BY "ds"."day"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."mv_scraping_activity_14d" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification" (
    "id" "text" NOT NULL,
    "to" "text" NOT NULL,
    "channel" "text" NOT NULL,
    "template" "text",
    "data" "jsonb",
    "trigger_type" "text",
    "resource_id" "text",
    "resource_type" "text",
    "receiver_id" "text",
    "original_notification_id" "text",
    "idempotency_key" "text",
    "external_id" "text",
    "provider_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "from" "text",
    "provider_data" "jsonb",
    CONSTRAINT "notification_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'success'::"text", 'failure'::"text"])))
);


ALTER TABLE "public"."notification" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification_provider" (
    "id" "text" NOT NULL,
    "handle" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_enabled" boolean DEFAULT true NOT NULL,
    "channels" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."notification_provider" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order" (
    "id" "text" NOT NULL,
    "region_id" "text",
    "display_id" integer,
    "customer_id" "text",
    "version" integer DEFAULT 1 NOT NULL,
    "sales_channel_id" "text",
    "status" "public"."order_status_enum" DEFAULT 'pending'::"public"."order_status_enum" NOT NULL,
    "is_draft_order" boolean DEFAULT false NOT NULL,
    "email" "text",
    "currency_code" "text" NOT NULL,
    "shipping_address_id" "text",
    "billing_address_id" "text",
    "no_notification" boolean,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "canceled_at" timestamp with time zone,
    "custom_display_id" "text",
    "locale" "text"
);


ALTER TABLE "public"."order" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_address" (
    "id" "text" NOT NULL,
    "customer_id" "text",
    "company" "text",
    "first_name" "text",
    "last_name" "text",
    "address_1" "text",
    "address_2" "text",
    "city" "text",
    "country_code" "text",
    "province" "text",
    "postal_code" "text",
    "phone" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_address" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_cart" (
    "order_id" character varying(255) NOT NULL,
    "cart_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_cart" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_change" (
    "id" "text" NOT NULL,
    "order_id" "text" NOT NULL,
    "version" integer NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "internal_note" "text",
    "created_by" "text",
    "requested_by" "text",
    "requested_at" timestamp with time zone,
    "confirmed_by" "text",
    "confirmed_at" timestamp with time zone,
    "declined_by" "text",
    "declined_reason" "text",
    "metadata" "jsonb",
    "declined_at" timestamp with time zone,
    "canceled_by" "text",
    "canceled_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "change_type" "text",
    "deleted_at" timestamp with time zone,
    "return_id" "text",
    "claim_id" "text",
    "exchange_id" "text",
    "carry_over_promotions" boolean,
    CONSTRAINT "order_change_status_check" CHECK (("status" = ANY (ARRAY['confirmed'::"text", 'declined'::"text", 'requested'::"text", 'pending'::"text", 'canceled'::"text"])))
);


ALTER TABLE "public"."order_change" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_change_action" (
    "id" "text" NOT NULL,
    "order_id" "text",
    "version" integer,
    "ordering" bigint NOT NULL,
    "order_change_id" "text",
    "reference" "text",
    "reference_id" "text",
    "action" "text" NOT NULL,
    "details" "jsonb",
    "amount" numeric,
    "raw_amount" "jsonb",
    "internal_note" "text",
    "applied" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "return_id" "text",
    "claim_id" "text",
    "exchange_id" "text"
);


ALTER TABLE "public"."order_change_action" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."order_change_action_ordering_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."order_change_action_ordering_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."order_change_action_ordering_seq" OWNED BY "public"."order_change_action"."ordering";



CREATE TABLE IF NOT EXISTS "public"."order_claim" (
    "id" "text" NOT NULL,
    "order_id" "text" NOT NULL,
    "return_id" "text",
    "order_version" integer NOT NULL,
    "display_id" integer NOT NULL,
    "type" "public"."order_claim_type_enum" NOT NULL,
    "no_notification" boolean,
    "refund_amount" numeric,
    "raw_refund_amount" "jsonb",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "canceled_at" timestamp with time zone,
    "created_by" "text"
);


ALTER TABLE "public"."order_claim" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."order_claim_display_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."order_claim_display_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."order_claim_display_id_seq" OWNED BY "public"."order_claim"."display_id";



CREATE TABLE IF NOT EXISTS "public"."order_claim_item" (
    "id" "text" NOT NULL,
    "claim_id" "text" NOT NULL,
    "item_id" "text" NOT NULL,
    "is_additional_item" boolean DEFAULT false NOT NULL,
    "reason" "public"."claim_reason_enum",
    "quantity" numeric NOT NULL,
    "raw_quantity" "jsonb" NOT NULL,
    "note" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_claim_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_claim_item_image" (
    "id" "text" NOT NULL,
    "claim_item_id" "text" NOT NULL,
    "url" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_claim_item_image" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_credit_line" (
    "id" "text" NOT NULL,
    "order_id" "text" NOT NULL,
    "reference" "text",
    "reference_id" "text",
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "version" integer DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."order_credit_line" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."order_display_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."order_display_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."order_display_id_seq" OWNED BY "public"."order"."display_id";



CREATE TABLE IF NOT EXISTS "public"."order_exchange" (
    "id" "text" NOT NULL,
    "order_id" "text" NOT NULL,
    "return_id" "text",
    "order_version" integer NOT NULL,
    "display_id" integer NOT NULL,
    "no_notification" boolean,
    "allow_backorder" boolean DEFAULT false NOT NULL,
    "difference_due" numeric,
    "raw_difference_due" "jsonb",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "canceled_at" timestamp with time zone,
    "created_by" "text"
);


ALTER TABLE "public"."order_exchange" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."order_exchange_display_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."order_exchange_display_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."order_exchange_display_id_seq" OWNED BY "public"."order_exchange"."display_id";



CREATE TABLE IF NOT EXISTS "public"."order_exchange_item" (
    "id" "text" NOT NULL,
    "exchange_id" "text" NOT NULL,
    "item_id" "text" NOT NULL,
    "quantity" numeric NOT NULL,
    "raw_quantity" "jsonb" NOT NULL,
    "note" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_exchange_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_fulfillment" (
    "order_id" character varying(255) NOT NULL,
    "fulfillment_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_fulfillment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_item" (
    "id" "text" NOT NULL,
    "order_id" "text" NOT NULL,
    "version" integer NOT NULL,
    "item_id" "text" NOT NULL,
    "quantity" numeric NOT NULL,
    "raw_quantity" "jsonb" NOT NULL,
    "fulfilled_quantity" numeric NOT NULL,
    "raw_fulfilled_quantity" "jsonb" DEFAULT '{"value": "0", "precision": 20}'::"jsonb" NOT NULL,
    "shipped_quantity" numeric NOT NULL,
    "raw_shipped_quantity" "jsonb" DEFAULT '{"value": "0", "precision": 20}'::"jsonb" NOT NULL,
    "return_requested_quantity" numeric NOT NULL,
    "raw_return_requested_quantity" "jsonb" DEFAULT '{"value": "0", "precision": 20}'::"jsonb" NOT NULL,
    "return_received_quantity" numeric NOT NULL,
    "raw_return_received_quantity" "jsonb" DEFAULT '{"value": "0", "precision": 20}'::"jsonb" NOT NULL,
    "return_dismissed_quantity" numeric NOT NULL,
    "raw_return_dismissed_quantity" "jsonb" DEFAULT '{"value": "0", "precision": 20}'::"jsonb" NOT NULL,
    "written_off_quantity" numeric NOT NULL,
    "raw_written_off_quantity" "jsonb" DEFAULT '{"value": "0", "precision": 20}'::"jsonb" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "delivered_quantity" numeric DEFAULT 0 NOT NULL,
    "raw_delivered_quantity" "jsonb" DEFAULT '{"value": "0", "precision": 20}'::"jsonb" NOT NULL,
    "unit_price" numeric,
    "raw_unit_price" "jsonb",
    "compare_at_unit_price" numeric,
    "raw_compare_at_unit_price" "jsonb"
);


ALTER TABLE "public"."order_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_line_item" (
    "id" "text" NOT NULL,
    "totals_id" "text",
    "title" "text" NOT NULL,
    "subtitle" "text",
    "thumbnail" "text",
    "variant_id" "text",
    "product_id" "text",
    "product_title" "text",
    "product_description" "text",
    "product_subtitle" "text",
    "product_type" "text",
    "product_collection" "text",
    "product_handle" "text",
    "variant_sku" "text",
    "variant_barcode" "text",
    "variant_title" "text",
    "variant_option_values" "jsonb",
    "requires_shipping" boolean DEFAULT true NOT NULL,
    "is_discountable" boolean DEFAULT true NOT NULL,
    "is_tax_inclusive" boolean DEFAULT false NOT NULL,
    "compare_at_unit_price" numeric,
    "raw_compare_at_unit_price" "jsonb",
    "unit_price" numeric NOT NULL,
    "raw_unit_price" "jsonb" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "is_custom_price" boolean DEFAULT false NOT NULL,
    "product_type_id" "text",
    "is_giftcard" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."order_line_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_line_item_adjustment" (
    "id" "text" NOT NULL,
    "description" "text",
    "promotion_id" "text",
    "code" "text",
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "provider_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "item_id" "text" NOT NULL,
    "deleted_at" timestamp with time zone,
    "is_tax_inclusive" boolean DEFAULT false NOT NULL,
    "version" integer DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."order_line_item_adjustment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_line_item_tax_line" (
    "id" "text" NOT NULL,
    "description" "text",
    "tax_rate_id" "text",
    "code" "text" NOT NULL,
    "rate" numeric NOT NULL,
    "raw_rate" "jsonb" NOT NULL,
    "provider_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "item_id" "text" NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_line_item_tax_line" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_payment_collection" (
    "order_id" character varying(255) NOT NULL,
    "payment_collection_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_payment_collection" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_promotion" (
    "order_id" character varying(255) NOT NULL,
    "promotion_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_promotion" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_shipping" (
    "id" "text" NOT NULL,
    "order_id" "text" NOT NULL,
    "version" integer NOT NULL,
    "shipping_method_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "return_id" "text",
    "claim_id" "text",
    "exchange_id" "text"
);


ALTER TABLE "public"."order_shipping" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_shipping_method" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "jsonb",
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "is_tax_inclusive" boolean DEFAULT false NOT NULL,
    "shipping_option_id" "text",
    "data" "jsonb",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "is_custom_amount" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."order_shipping_method" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_shipping_method_adjustment" (
    "id" "text" NOT NULL,
    "description" "text",
    "promotion_id" "text",
    "code" "text",
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "provider_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "shipping_method_id" "text" NOT NULL,
    "deleted_at" timestamp with time zone,
    "version" integer DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."order_shipping_method_adjustment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_shipping_method_tax_line" (
    "id" "text" NOT NULL,
    "description" "text",
    "tax_rate_id" "text",
    "code" "text" NOT NULL,
    "rate" numeric NOT NULL,
    "raw_rate" "jsonb" NOT NULL,
    "provider_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "shipping_method_id" "text" NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_shipping_method_tax_line" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_summary" (
    "id" "text" NOT NULL,
    "order_id" "text" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "totals" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."order_summary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_transaction" (
    "id" "text" NOT NULL,
    "order_id" "text" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "currency_code" "text" NOT NULL,
    "reference" "text",
    "reference_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "return_id" "text",
    "claim_id" "text",
    "exchange_id" "text"
);


ALTER TABLE "public"."order_transaction" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment" (
    "id" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "currency_code" "text" NOT NULL,
    "provider_id" "text" NOT NULL,
    "data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "captured_at" timestamp with time zone,
    "canceled_at" timestamp with time zone,
    "payment_collection_id" "text" NOT NULL,
    "payment_session_id" "text" NOT NULL,
    "metadata" "jsonb"
);


ALTER TABLE "public"."payment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_collection" (
    "id" "text" NOT NULL,
    "currency_code" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "authorized_amount" numeric,
    "raw_authorized_amount" "jsonb",
    "captured_amount" numeric,
    "raw_captured_amount" "jsonb",
    "refunded_amount" numeric,
    "raw_refunded_amount" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "status" "text" DEFAULT 'not_paid'::"text" NOT NULL,
    "metadata" "jsonb",
    CONSTRAINT "payment_collection_status_check" CHECK (("status" = ANY (ARRAY['not_paid'::"text", 'awaiting'::"text", 'authorized'::"text", 'partially_authorized'::"text", 'canceled'::"text", 'failed'::"text", 'partially_captured'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."payment_collection" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_collection_payment_providers" (
    "payment_collection_id" "text" NOT NULL,
    "payment_provider_id" "text" NOT NULL
);


ALTER TABLE "public"."payment_collection_payment_providers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_provider" (
    "id" "text" NOT NULL,
    "is_enabled" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."payment_provider" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_session" (
    "id" "text" NOT NULL,
    "currency_code" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "provider_id" "text" NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "context" "jsonb",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "authorized_at" timestamp with time zone,
    "payment_collection_id" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "payment_session_status_check" CHECK (("status" = ANY (ARRAY['authorized'::"text", 'captured'::"text", 'pending'::"text", 'requires_more'::"text", 'error'::"text", 'canceled'::"text"])))
);


ALTER TABLE "public"."payment_session" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price" (
    "id" "text" NOT NULL,
    "title" "text",
    "price_set_id" "text" NOT NULL,
    "currency_code" "text" NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "rules_count" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "price_list_id" "text",
    "amount" numeric NOT NULL,
    "min_quantity" numeric,
    "max_quantity" numeric,
    "raw_min_quantity" "jsonb",
    "raw_max_quantity" "jsonb"
);


ALTER TABLE "public"."price" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_history" (
    "id" bigint NOT NULL,
    "product_id" "text" NOT NULL,
    "ean" "text",
    "source" "text" NOT NULL,
    "price" numeric NOT NULL,
    "recorded_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."price_history" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."price_history_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."price_history_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."price_history_id_seq" OWNED BY "public"."price_history"."id";



CREATE TABLE IF NOT EXISTS "public"."price_list" (
    "id" "text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "rules_count" integer DEFAULT 0,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "type" "text" DEFAULT 'sale'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "metadata" "jsonb",
    CONSTRAINT "price_list_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'draft'::"text"]))),
    CONSTRAINT "price_list_type_check" CHECK (("type" = ANY (ARRAY['sale'::"text", 'override'::"text"])))
);


ALTER TABLE "public"."price_list" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_list_rule" (
    "id" "text" NOT NULL,
    "price_list_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "value" "jsonb",
    "attribute" "text" DEFAULT ''::"text" NOT NULL
);


ALTER TABLE "public"."price_list_rule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_preference" (
    "id" "text" NOT NULL,
    "attribute" "text" NOT NULL,
    "value" "text",
    "is_tax_inclusive" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."price_preference" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_rule" (
    "id" "text" NOT NULL,
    "value" "text" NOT NULL,
    "priority" integer DEFAULT 0 NOT NULL,
    "price_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "attribute" "text" DEFAULT ''::"text" NOT NULL,
    "operator" "text" DEFAULT 'eq'::"text" NOT NULL,
    CONSTRAINT "price_rule_operator_check" CHECK (("operator" = ANY (ARRAY['gte'::"text", 'lte'::"text", 'gt'::"text", 'lt'::"text", 'eq'::"text"])))
);


ALTER TABLE "public"."price_rule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_set" (
    "id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."price_set" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product" (
    "id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "handle" "text" NOT NULL,
    "subtitle" "text",
    "description" "text",
    "is_giftcard" boolean DEFAULT false NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "thumbnail" "text",
    "weight" "text",
    "length" "text",
    "height" "text",
    "width" "text",
    "origin_country" "text",
    "hs_code" "text",
    "mid_code" "text",
    "material" "text",
    "collection_id" "text",
    "type_id" "text",
    "discountable" boolean DEFAULT true NOT NULL,
    "external_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "metadata" "jsonb",
    CONSTRAINT "product_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'proposed'::"text", 'published'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."product" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_category" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "handle" "text" NOT NULL,
    "mpath" "text" NOT NULL,
    "is_active" boolean DEFAULT false NOT NULL,
    "is_internal" boolean DEFAULT false NOT NULL,
    "rank" integer DEFAULT 0 NOT NULL,
    "parent_category_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "metadata" "jsonb",
    "external_id" "text"
);


ALTER TABLE "public"."product_category" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_category_product" (
    "product_id" "text" NOT NULL,
    "product_category_id" "text" NOT NULL
);


ALTER TABLE "public"."product_category_product" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_collection" (
    "id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "handle" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "external_id" "text"
);


ALTER TABLE "public"."product_collection" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_option" (
    "id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "product_id" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."product_option" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_option_value" (
    "id" "text" NOT NULL,
    "value" "text" NOT NULL,
    "option_id" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."product_option_value" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_sales_channel" (
    "product_id" character varying(255) NOT NULL,
    "sales_channel_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."product_sales_channel" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_shipping_profile" (
    "product_id" character varying(255) NOT NULL,
    "shipping_profile_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."product_shipping_profile" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_tag" (
    "id" "text" NOT NULL,
    "value" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "external_id" "text"
);


ALTER TABLE "public"."product_tag" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_tags" (
    "product_id" "text" NOT NULL,
    "product_tag_id" "text" NOT NULL
);


ALTER TABLE "public"."product_tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_type" (
    "id" "text" NOT NULL,
    "value" "text" NOT NULL,
    "metadata" json,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "external_id" "text"
);


ALTER TABLE "public"."product_type" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_variant" (
    "id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "sku" "text",
    "barcode" "text",
    "ean" "text",
    "upc" "text",
    "allow_backorder" boolean DEFAULT false NOT NULL,
    "manage_inventory" boolean DEFAULT true NOT NULL,
    "hs_code" "text",
    "origin_country" "text",
    "mid_code" "text",
    "material" "text",
    "weight" integer,
    "length" integer,
    "height" integer,
    "width" integer,
    "metadata" "jsonb",
    "variant_rank" integer DEFAULT 0,
    "product_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "thumbnail" "text"
);


ALTER TABLE "public"."product_variant" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_variant_inventory_item" (
    "variant_id" character varying(255) NOT NULL,
    "inventory_item_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "required_quantity" integer DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."product_variant_inventory_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_variant_option" (
    "variant_id" "text" NOT NULL,
    "option_value_id" "text" NOT NULL
);


ALTER TABLE "public"."product_variant_option" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_variant_price_set" (
    "variant_id" character varying(255) NOT NULL,
    "price_set_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."product_variant_price_set" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_variant_product_image" (
    "id" "text" NOT NULL,
    "variant_id" "text" NOT NULL,
    "image_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."product_variant_product_image" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."products_to_translate" (
    "id" "uuid" NOT NULL,
    "name" "text",
    "specs" "jsonb",
    "category_path" "text"[],
    "description" "text",
    "source" "text",
    "ean" "text"
);


ALTER TABLE "public"."products_to_translate" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promotion" (
    "id" "text" NOT NULL,
    "code" "text" NOT NULL,
    "campaign_id" "text",
    "is_automatic" boolean DEFAULT false NOT NULL,
    "type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "is_tax_inclusive" boolean DEFAULT false NOT NULL,
    "limit" integer,
    "used" integer DEFAULT 0 NOT NULL,
    "metadata" "jsonb",
    CONSTRAINT "promotion_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'inactive'::"text"]))),
    CONSTRAINT "promotion_type_check" CHECK (("type" = ANY (ARRAY['standard'::"text", 'buyget'::"text"])))
);


ALTER TABLE "public"."promotion" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promotion_application_method" (
    "id" "text" NOT NULL,
    "value" numeric,
    "raw_value" "jsonb",
    "max_quantity" integer,
    "apply_to_quantity" integer,
    "buy_rules_min_quantity" integer,
    "type" "text" NOT NULL,
    "target_type" "text" NOT NULL,
    "allocation" "text",
    "promotion_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "currency_code" "text",
    CONSTRAINT "promotion_application_method_allocation_check" CHECK (("allocation" = ANY (ARRAY['each'::"text", 'across'::"text", 'once'::"text"]))),
    CONSTRAINT "promotion_application_method_target_type_check" CHECK (("target_type" = ANY (ARRAY['order'::"text", 'shipping_methods'::"text", 'items'::"text"]))),
    CONSTRAINT "promotion_application_method_type_check" CHECK (("type" = ANY (ARRAY['fixed'::"text", 'percentage'::"text"])))
);


ALTER TABLE "public"."promotion_application_method" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promotion_campaign" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "campaign_identifier" "text" NOT NULL,
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."promotion_campaign" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promotion_campaign_budget" (
    "id" "text" NOT NULL,
    "type" "text" NOT NULL,
    "campaign_id" "text" NOT NULL,
    "limit" numeric,
    "raw_limit" "jsonb",
    "used" numeric DEFAULT 0 NOT NULL,
    "raw_used" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "currency_code" "text",
    "attribute" "text",
    CONSTRAINT "promotion_campaign_budget_type_check" CHECK (("type" = ANY (ARRAY['spend'::"text", 'usage'::"text", 'use_by_attribute'::"text", 'spend_by_attribute'::"text"])))
);


ALTER TABLE "public"."promotion_campaign_budget" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promotion_campaign_budget_usage" (
    "id" "text" NOT NULL,
    "attribute_value" "text" NOT NULL,
    "used" numeric DEFAULT 0 NOT NULL,
    "budget_id" "text" NOT NULL,
    "raw_used" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."promotion_campaign_budget_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promotion_promotion_rule" (
    "promotion_id" "text" NOT NULL,
    "promotion_rule_id" "text" NOT NULL
);


ALTER TABLE "public"."promotion_promotion_rule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promotion_rule" (
    "id" "text" NOT NULL,
    "description" "text",
    "attribute" "text" NOT NULL,
    "operator" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "promotion_rule_operator_check" CHECK (("operator" = ANY (ARRAY['gte'::"text", 'lte'::"text", 'gt'::"text", 'lt'::"text", 'eq'::"text", 'ne'::"text", 'in'::"text"])))
);


ALTER TABLE "public"."promotion_rule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promotion_rule_value" (
    "id" "text" NOT NULL,
    "promotion_rule_id" "text" NOT NULL,
    "value" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."promotion_rule_value" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."property_label" (
    "id" "text" NOT NULL,
    "entity" "text" NOT NULL,
    "property" "text" NOT NULL,
    "label" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."property_label" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."provider_identity" (
    "id" "text" NOT NULL,
    "entity_id" "text" NOT NULL,
    "provider" "text" NOT NULL,
    "auth_identity_id" "text" NOT NULL,
    "user_metadata" "jsonb",
    "provider_metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."provider_identity" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."publishable_api_key_sales_channel" (
    "publishable_key_id" character varying(255) NOT NULL,
    "sales_channel_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."publishable_api_key_sales_channel" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."refund" (
    "id" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "raw_amount" "jsonb" NOT NULL,
    "payment_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "created_by" "text",
    "metadata" "jsonb",
    "refund_reason_id" "text",
    "note" "text"
);


ALTER TABLE "public"."refund" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."refund_reason" (
    "id" "text" NOT NULL,
    "label" "text" NOT NULL,
    "description" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "code" "text" NOT NULL
);


ALTER TABLE "public"."refund_reason" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."refurbished_products" (
    "id" bigint NOT NULL,
    "source" "text" NOT NULL,
    "sku" "text" NOT NULL,
    "ean" "text",
    "name" "text" NOT NULL,
    "name_fr" "text",
    "description" "text",
    "description_fr" "text",
    "brand" "text",
    "price" numeric,
    "price_previous" numeric,
    "price_drop_pct" numeric,
    "price_history" "jsonb" DEFAULT '[]'::"jsonb",
    "is_price_drop" boolean DEFAULT false,
    "image_url" "text",
    "images_all" "jsonb",
    "product_url" "text",
    "category" "text",
    "condition" "text",
    "grade" "text",
    "grade_fr" "text",
    "keyboard_layout" "text",
    "specs" "jsonb",
    "specs_fr" "jsonb",
    "is_refurbished" boolean DEFAULT true,
    "is_promo" boolean DEFAULT false,
    "in_stock" boolean DEFAULT true,
    "stock_status" "text" DEFAULT 'available'::"text",
    "delivery_time" "text",
    "quantity" integer DEFAULT 1,
    "country_code" "text" DEFAULT 'DE'::"text",
    "medusa_id" "text",
    "translated_at" timestamp with time zone,
    "first_seen" timestamp with time zone DEFAULT "now"(),
    "last_scraped" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "category_main" "text",
    "image_r2_url" "text",
    "image_r2_at" timestamp with time zone
);


ALTER TABLE "public"."refurbished_products" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."refurbished_products_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."refurbished_products_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."refurbished_products_id_seq" OWNED BY "public"."refurbished_products"."id";



CREATE TABLE IF NOT EXISTS "public"."region" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "currency_code" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "automatic_taxes" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."region" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."region_country" (
    "iso_2" "text" NOT NULL,
    "iso_3" "text" NOT NULL,
    "num_code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "region_id" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."region_country" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."region_payment_provider" (
    "region_id" character varying(255) NOT NULL,
    "payment_provider_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."region_payment_provider" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reservation_item" (
    "id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "line_item_id" "text",
    "location_id" "text" NOT NULL,
    "quantity" numeric NOT NULL,
    "external_id" "text",
    "description" "text",
    "created_by" "text",
    "metadata" "jsonb",
    "inventory_item_id" "text" NOT NULL,
    "allow_backorder" boolean DEFAULT false,
    "raw_quantity" "jsonb"
);


ALTER TABLE "public"."reservation_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."return" (
    "id" "text" NOT NULL,
    "order_id" "text" NOT NULL,
    "claim_id" "text",
    "exchange_id" "text",
    "order_version" integer NOT NULL,
    "display_id" integer NOT NULL,
    "status" "public"."return_status_enum" DEFAULT 'open'::"public"."return_status_enum" NOT NULL,
    "no_notification" boolean,
    "refund_amount" numeric,
    "raw_refund_amount" "jsonb",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "received_at" timestamp with time zone,
    "canceled_at" timestamp with time zone,
    "location_id" "text",
    "requested_at" timestamp with time zone,
    "created_by" "text"
);


ALTER TABLE "public"."return" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."return_display_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."return_display_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."return_display_id_seq" OWNED BY "public"."return"."display_id";



CREATE TABLE IF NOT EXISTS "public"."return_fulfillment" (
    "return_id" character varying(255) NOT NULL,
    "fulfillment_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."return_fulfillment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."return_item" (
    "id" "text" NOT NULL,
    "return_id" "text" NOT NULL,
    "reason_id" "text",
    "item_id" "text" NOT NULL,
    "quantity" numeric NOT NULL,
    "raw_quantity" "jsonb" NOT NULL,
    "received_quantity" numeric DEFAULT 0 NOT NULL,
    "raw_received_quantity" "jsonb" DEFAULT '{"value": "0", "precision": 20}'::"jsonb" NOT NULL,
    "note" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "damaged_quantity" numeric DEFAULT 0 NOT NULL,
    "raw_damaged_quantity" "jsonb" DEFAULT '{"value": "0", "precision": 20}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."return_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."return_reason" (
    "id" character varying NOT NULL,
    "value" character varying NOT NULL,
    "label" character varying NOT NULL,
    "description" character varying,
    "metadata" "jsonb",
    "parent_return_reason_id" character varying,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."return_reason" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sales_channel" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_disabled" boolean DEFAULT false NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."sales_channel" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sales_channel_stock_location" (
    "sales_channel_id" character varying(255) NOT NULL,
    "stock_location_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."sales_channel_stock_location" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."scrape_queue" (
    "id" integer NOT NULL,
    "url" "text" NOT NULL,
    "source" "text" DEFAULT 'siko'::"text",
    "status" "text" DEFAULT 'pending'::"text",
    "retries" integer DEFAULT 0,
    "last_attempt" timestamp with time zone,
    "error_msg" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."scrape_queue" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."scrape_queue_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."scrape_queue_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."scrape_queue_id_seq" OWNED BY "public"."scrape_queue"."id";



CREATE TABLE IF NOT EXISTS "public"."scraper_status" (
    "source" "text" NOT NULL,
    "total_produits" bigint DEFAULT 0,
    "derniere_activite" timestamp with time zone,
    "nouveaux_1h" bigint DEFAULT 0,
    "modifies_1h" bigint DEFAULT 0,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."scraper_status" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."scraping_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "scrape_type" "text" NOT NULL,
    "pages_scraped" integer DEFAULT 0,
    "products_found" integer DEFAULT 0,
    "products_new" integer DEFAULT 0,
    "products_updated" integer DEFAULT 0,
    "errors" "jsonb" DEFAULT '[]'::"jsonb",
    "started_at" timestamp with time zone DEFAULT "now"(),
    "finished_at" timestamp with time zone,
    "status" "text" DEFAULT 'running'::"text",
    "source" "text",
    "run_type" "text",
    "duration_seconds" integer DEFAULT 0,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "elapsed_sec" numeric
);


ALTER TABLE "public"."scraping_logs" OWNER TO "postgres";


COMMENT ON COLUMN "public"."scraping_logs"."run_type" IS 'Type de run : full | update | deals | catalog';



COMMENT ON COLUMN "public"."scraping_logs"."duration_seconds" IS 'Durée du run en secondes';



COMMENT ON COLUMN "public"."scraping_logs"."metadata" IS 'Métadonnées JSON pour analytics';



CREATE TABLE IF NOT EXISTS "public"."script_migrations" (
    "id" integer NOT NULL,
    "script_name" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "finished_at" timestamp with time zone
);


ALTER TABLE "public"."script_migrations" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."script_migrations_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."script_migrations_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."script_migrations_id_seq" OWNED BY "public"."script_migrations"."id";



CREATE TABLE IF NOT EXISTS "public"."secondbuy_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source" "text" DEFAULT 'secondbuy'::"text",
    "sku" "text" NOT NULL,
    "ean" "text",
    "name" "text",
    "description" "text",
    "brand" "text",
    "price" numeric,
    "image_url" "text",
    "product_url" "text",
    "category" "text",
    "condition" "text",
    "is_refurbished" boolean DEFAULT true,
    "in_stock" boolean DEFAULT true,
    "country_code" "text" DEFAULT 'DE'::"text",
    "last_scraped" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "grade" "text",
    "keyboard_layout" "text",
    "specs" "jsonb",
    "images_all" "jsonb",
    "name_fr" "text",
    "description_fr" "text",
    "specs_fr" "jsonb",
    "translated_at" timestamp with time zone,
    "first_seen" timestamp with time zone DEFAULT "now"(),
    "medusa_id" "text"
);


ALTER TABLE "public"."secondbuy_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."secondbuy_stock_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "snapshot_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "total_products" integer,
    "total_notebooks" integer,
    "total_pc" integer,
    "total_smartphones" integer,
    "total_tablets" integer,
    "new_products" integer,
    "sold_products" integer,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."secondbuy_stock_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."service_zone" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "metadata" "jsonb",
    "fulfillment_set_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."service_zone" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shipping_option" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "price_type" "text" DEFAULT 'flat'::"text" NOT NULL,
    "service_zone_id" "text" NOT NULL,
    "shipping_profile_id" "text",
    "provider_id" "text",
    "data" "jsonb",
    "metadata" "jsonb",
    "shipping_option_type_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "shipping_option_price_type_check" CHECK (("price_type" = ANY (ARRAY['calculated'::"text", 'flat'::"text"])))
);


ALTER TABLE "public"."shipping_option" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shipping_option_price_set" (
    "shipping_option_id" character varying(255) NOT NULL,
    "price_set_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."shipping_option_price_set" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shipping_option_rule" (
    "id" "text" NOT NULL,
    "attribute" "text" NOT NULL,
    "operator" "text" NOT NULL,
    "value" "jsonb",
    "shipping_option_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "shipping_option_rule_operator_check" CHECK (("operator" = ANY (ARRAY['in'::"text", 'eq'::"text", 'ne'::"text", 'gt'::"text", 'gte'::"text", 'lt'::"text", 'lte'::"text", 'nin'::"text"])))
);


ALTER TABLE "public"."shipping_option_rule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shipping_option_type" (
    "id" "text" NOT NULL,
    "label" "text" NOT NULL,
    "description" "text",
    "code" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."shipping_option_type" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shipping_profile" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."shipping_profile" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stock_location" (
    "id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "name" "text" NOT NULL,
    "address_id" "text",
    "metadata" "jsonb"
);


ALTER TABLE "public"."stock_location" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stock_location_address" (
    "id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "address_1" "text" NOT NULL,
    "address_2" "text",
    "company" "text",
    "city" "text",
    "country_code" "text" NOT NULL,
    "phone" "text",
    "province" "text",
    "postal_code" "text",
    "metadata" "jsonb"
);


ALTER TABLE "public"."stock_location_address" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."store" (
    "id" "text" NOT NULL,
    "name" "text" DEFAULT 'Medusa Store'::"text" NOT NULL,
    "default_sales_channel_id" "text",
    "default_region_id" "text",
    "default_location_id" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."store" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."store_currency" (
    "id" "text" NOT NULL,
    "currency_code" "text" NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "store_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."store_currency" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."store_locale" (
    "id" "text" NOT NULL,
    "locale_code" "text" NOT NULL,
    "store_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."store_locale" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tax_provider" (
    "id" "text" NOT NULL,
    "is_enabled" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."tax_provider" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tax_rate" (
    "id" "text" NOT NULL,
    "rate" real,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "is_combinable" boolean DEFAULT false NOT NULL,
    "tax_region_id" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "text",
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."tax_rate" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tax_rate_rule" (
    "id" "text" NOT NULL,
    "tax_rate_id" "text" NOT NULL,
    "reference_id" "text" NOT NULL,
    "reference" "text" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "text",
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."tax_rate_rule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tax_region" (
    "id" "text" NOT NULL,
    "provider_id" "text",
    "country_code" "text" NOT NULL,
    "province_code" "text",
    "parent_id" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "text",
    "deleted_at" timestamp with time zone,
    CONSTRAINT "CK_tax_region_country_top_level" CHECK ((("parent_id" IS NULL) OR ("province_code" IS NOT NULL))),
    CONSTRAINT "CK_tax_region_provider_top_level" CHECK ((("parent_id" IS NULL) OR ("provider_id" IS NULL)))
);


ALTER TABLE "public"."tax_region" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."technikdirekt_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text",
    "brand" "text",
    "sku" "text",
    "ean" "text",
    "price" "text",
    "price_original" "text",
    "price_unit" "text",
    "currency" "text" DEFAULT 'EUR'::"text",
    "availability" "text",
    "delivery_info" "text",
    "category" "text",
    "subcategory" "text",
    "description" "text",
    "image_url" "text",
    "image_urls" "text",
    "product_url" "text" NOT NULL,
    "rating" "text",
    "review_count" "text",
    "specifications" "text",
    "weight" "text",
    "dimensions" "text",
    "is_variant" boolean DEFAULT false,
    "parent_url" "text",
    "variant_label" "text",
    "variant_group" "text",
    "variant_value" "text",
    "all_variants" "text",
    "scraped_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source" "text" DEFAULT 'technikdirekt'::"text" NOT NULL,
    "price_num" numeric(12,2),
    "price_original_num" numeric(12,2),
    "specifications_json" "jsonb",
    "image_urls_json" "jsonb",
    "all_variants_json" "jsonb"
);


ALTER TABLE "public"."technikdirekt_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user" (
    "id" "text" NOT NULL,
    "first_name" "text",
    "last_name" "text",
    "email" "text" NOT NULL,
    "avatar_url" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."user" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_preference" (
    "id" "text" NOT NULL,
    "user_id" "text" NOT NULL,
    "key" "text" NOT NULL,
    "value" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."user_preference" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_rbac_role" (
    "user_id" character varying(255) NOT NULL,
    "rbac_role_id" character varying(255) NOT NULL,
    "id" character varying(255) NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."user_rbac_role" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."v_active_blitzangebote" AS
 SELECT "p"."id",
    "p"."voelkner_id",
    "p"."name",
    "p"."ean",
    "p"."brand_name",
    "p"."category_path",
    "p"."product_url",
    "p"."image_url",
    "p"."deal_end_timestamp",
    "p"."deal_end_date",
    "round"((EXTRACT(epoch FROM ("p"."deal_end_date" - "now"())) / (3600)::numeric), 1) AS "hours_remaining",
    (("p"."deal_time_remaining" ->> 'days'::"text"))::integer AS "days_left",
    (("p"."deal_time_remaining" ->> 'hours'::"text"))::integer AS "hours_left",
    (("p"."deal_time_remaining" ->> 'minutes'::"text"))::integer AS "minutes_left",
    "p"."is_sale",
    "p"."mr_compatible",
    "p"."created_at",
    "ps"."price_current",
    "ps"."price_before",
    "ps"."drop_percent",
    "ps"."in_stock" AS "stock_available",
    "ps"."scraped_at" AS "price_updated_at"
   FROM ("public"."products" "p"
     LEFT JOIN LATERAL ( SELECT "price_snapshots"."price_current",
            "price_snapshots"."price_before",
            "price_snapshots"."drop_percent",
            "price_snapshots"."in_stock",
            "price_snapshots"."scraped_at"
           FROM "public"."price_snapshots"
          WHERE ("price_snapshots"."product_id" = "p"."id")
          ORDER BY "price_snapshots"."scraped_at" DESC
         LIMIT 1) "ps" ON (true))
  WHERE (("p"."is_blitzangebot" = true) AND ("p"."deal_end_timestamp" IS NOT NULL) AND (("p"."deal_end_timestamp")::numeric > EXTRACT(epoch FROM "now"())) AND (("ps"."in_stock" = true) OR ("ps"."in_stock" IS NULL)))
  ORDER BY "p"."deal_end_timestamp"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."v_active_blitzangebote" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_dashboard_prices" AS
 SELECT "count"(*) FILTER (WHERE ("ps"."price_current" < "ps2"."price_current")) AS "price_down",
    "count"(*) FILTER (WHERE ("ps"."price_current" > "ps2"."price_current")) AS "price_up",
    "round"("avg"("ps"."drop_percent") FILTER (WHERE ("ps"."drop_percent" IS NOT NULL)), 1) AS "avg_drop"
   FROM ("public"."price_snapshots" "ps"
     JOIN "public"."price_snapshots" "ps2" ON ((("ps2"."product_id" = "ps"."product_id") AND ("ps2"."scraped_at" = ( SELECT "max"("price_snapshots"."scraped_at") AS "max"
           FROM "public"."price_snapshots"
          WHERE (("price_snapshots"."product_id" = "ps"."product_id") AND ("price_snapshots"."scraped_at" < "ps"."scraped_at")))))))
  WHERE ("ps"."scraped_at" >= ("now"() - '24:00:00'::interval));


ALTER VIEW "public"."v_dashboard_prices" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_dashboard_products" AS
 SELECT "source",
    "count"(*) AS "total",
    "count"(*) FILTER (WHERE ("created_at" >= ("now"() - '24:00:00'::interval))) AS "new_today",
    "count"(*) FILTER (WHERE ("created_at" >= ("now"() - '7 days'::interval))) AS "new_week"
   FROM "public"."products"
  GROUP BY "source";


ALTER VIEW "public"."v_dashboard_products" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."v_deals_blacklist_filtered" AS
 SELECT "ean",
    "count"(DISTINCT "source") AS "sources_count",
    "min"("unit_price") AS "min_price",
    "max"("unit_price") AS "max_price",
        CASE
            WHEN (("count"(DISTINCT "source") >= 2) AND ("max"("unit_price") > "min"("unit_price"))) THEN ((("max"("unit_price") - "min"("unit_price")) / "max"("unit_price")) * (100)::numeric)
            ELSE (0)::numeric
        END AS "discount_pct",
    ( SELECT "p2"."id"
           FROM "public"."mv_products_unit_price" "p2"
          WHERE ("p2"."ean" = "p"."ean")
          ORDER BY "p2"."unit_price"
         LIMIT 1) AS "best_product_id",
    ( SELECT "p2"."source"
           FROM "public"."mv_products_unit_price" "p2"
          WHERE ("p2"."ean" = "p"."ean")
          ORDER BY "p2"."unit_price"
         LIMIT 1) AS "best_source",
    ( SELECT "p2"."product_url"
           FROM "public"."mv_products_unit_price" "p2"
          WHERE ("p2"."ean" = "p"."ean")
          ORDER BY "p2"."unit_price"
         LIMIT 1) AS "best_product_url",
    ( SELECT "p2"."unit_price"
           FROM "public"."mv_products_unit_price" "p2"
          WHERE ("p2"."ean" = "p"."ean")
          ORDER BY "p2"."unit_price"
         LIMIT 1) AS "best_normalized_price",
    ( SELECT "p2"."pack_quantity"
           FROM "public"."mv_products_unit_price" "p2"
          WHERE ("p2"."ean" = "p"."ean")
          ORDER BY "p2"."unit_price"
         LIMIT 1) AS "best_pack_quantity"
   FROM "public"."mv_products_unit_price" "p"
  WHERE (("ean" IS NOT NULL) AND ("ean" <> ''::"text") AND ("unit_price" IS NOT NULL) AND ("unit_price" > (0)::numeric) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."deals_ean_blacklist" "bl"
          WHERE ("bl"."ean" = "p"."ean")))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."mv_bauhaus_blacklist_eans" "b"
          WHERE ("b"."ean" = "p"."ean")))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."mv_mr_keyword_blacklist_hits" "h"
          WHERE ("h"."ean" = "p"."ean")))))
  GROUP BY "ean"
 HAVING ("count"(DISTINCT "source") >= 2)
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."v_deals_blacklist_filtered" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_deals_latest" AS
 SELECT "p"."id",
    "p"."name",
    "p"."category",
    "p"."image_url",
    "p"."product_url",
    "p"."ean",
    "p"."is_brand_flagged",
    "p"."brand_name",
    "ps"."price_current",
    "ps"."price_before",
    "ps"."drop_percent",
    "ps"."best_merchant",
    "ps"."offers_count",
    "ps"."in_stock",
    "ps"."shipping_de",
    "ps"."is_free_shipping",
    "ps"."shipping_fr_estimated",
    "ps"."scraped_at",
    "round"((("ps"."price_current" + COALESCE("ps"."shipping_fr_estimated", 4.00)) * 1.15), 2) AS "suggested_fr_price"
   FROM ("public"."products" "p"
     JOIN "public"."price_snapshots" "ps" ON (("ps"."product_id" = "p"."id")))
  WHERE (("ps"."scraped_at" = ( SELECT "max"("ps2"."scraped_at") AS "max"
           FROM "public"."price_snapshots" "ps2"
          WHERE ("ps2"."product_id" = "p"."id"))) AND ("p"."is_brand_flagged" = false) AND ("ps"."in_stock" = true) AND ("p"."ean" IS NOT NULL) AND ("p"."ean" <> ''::"text") AND (COALESCE("p"."mr_compatible", false) = true) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."deals_ean_blacklist" "b"
          WHERE ("b"."ean" = "p"."ean")))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."mr_keyword_blacklist" "k"
          WHERE (("k"."active" = true) AND (COALESCE("p"."name", ''::"text") ~~* (('%'::"text" || "k"."keyword") || '%'::"text")))))));


ALTER VIEW "public"."v_deals_latest" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_price_comparison" AS
 SELECT "ean",
    "name",
    "brand",
    "max"(
        CASE
            WHEN ("source" = 'manomano'::"text") THEN "price"
            ELSE NULL::numeric
        END) AS "price_manomano_de",
    "max"(
        CASE
            WHEN ("source" = 'manomano_fr'::"text") THEN "price"
            ELSE NULL::numeric
        END) AS "price_manomano_fr",
    "max"(
        CASE
            WHEN ("source" = 'siko'::"text") THEN "price"
            ELSE NULL::numeric
        END) AS "price_siko",
    "max"(
        CASE
            WHEN ("source" = 'voelkner'::"text") THEN "price"
            ELSE NULL::numeric
        END) AS "price_voelkner",
    "max"(
        CASE
            WHEN ("source" = 'bauhaus'::"text") THEN "price"
            ELSE NULL::numeric
        END) AS "price_bauhaus",
    "max"(
        CASE
            WHEN ("source" = 'gotools'::"text") THEN "price"
            ELSE NULL::numeric
        END) AS "price_gotools",
    "max"(
        CASE
            WHEN ("source" = 'lefeld'::"text") THEN "price"
            ELSE NULL::numeric
        END) AS "price_lefeld",
    "max"(
        CASE
            WHEN ("source" = 'geizhals'::"text") THEN "price"
            ELSE NULL::numeric
        END) AS "price_geizhals",
    "min"("price") AS "price_min",
    "max"("price") AS "price_max",
    ("max"("price") - "min"("price")) AS "price_diff",
    ( SELECT "p2"."source"
           FROM "public"."products" "p2"
          WHERE (("p2"."ean" = "products"."ean") AND ("p2"."price" = "min"("products"."price")) AND ("p2"."price" IS NOT NULL))
         LIMIT 1) AS "best_supplier",
    "count"(
        CASE
            WHEN ("in_stock" = true) THEN 1
            ELSE NULL::integer
        END) AS "suppliers_in_stock",
    "count"(DISTINCT "source") AS "total_suppliers",
    "max"(
        CASE
            WHEN ("source" = 'manomano'::"text") THEN "product_url"
            ELSE NULL::"text"
        END) AS "url_manomano_de",
    "max"(
        CASE
            WHEN ("source" = 'manomano_fr'::"text") THEN "product_url"
            ELSE NULL::"text"
        END) AS "url_manomano_fr",
    "max"(
        CASE
            WHEN ("source" = 'siko'::"text") THEN "product_url"
            ELSE NULL::"text"
        END) AS "url_siko",
    "max"(
        CASE
            WHEN ("source" = 'voelkner'::"text") THEN "product_url"
            ELSE NULL::"text"
        END) AS "url_voelkner",
    "max"(
        CASE
            WHEN ("source" = 'bauhaus'::"text") THEN "product_url"
            ELSE NULL::"text"
        END) AS "url_bauhaus",
    "max"(
        CASE
            WHEN ("source" = 'gotools'::"text") THEN "product_url"
            ELSE NULL::"text"
        END) AS "url_gotools",
    "max"("image_url") AS "image_url",
    "max"("updated_at") AS "last_updated"
   FROM "public"."products"
  WHERE (("ean" IS NOT NULL) AND ("price" IS NOT NULL) AND ("price" > (0)::numeric))
  GROUP BY "ean", "name", "brand"
 HAVING ("count"(DISTINCT "source") >= 1)
  ORDER BY ("max"("price") - "min"("price")) DESC;


ALTER VIEW "public"."v_price_comparison" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_price_drops" AS
 WITH "latest_prices" AS (
         SELECT DISTINCT ON ("price_snapshots"."product_id") "price_snapshots"."product_id",
            "price_snapshots"."price_current" AS "current_price",
            "price_snapshots"."scraped_at" AS "current_date"
           FROM "public"."price_snapshots"
          ORDER BY "price_snapshots"."product_id", "price_snapshots"."scraped_at" DESC
        ), "previous_prices" AS (
         SELECT DISTINCT ON ("ps"."product_id") "ps"."product_id",
            "ps"."price_current" AS "previous_price",
            "ps"."scraped_at" AS "previous_date"
           FROM "public"."price_snapshots" "ps"
          WHERE ("ps"."scraped_at" < ( SELECT "price_snapshots"."scraped_at"
                   FROM "public"."price_snapshots"
                  WHERE ("price_snapshots"."product_id" = "ps"."product_id")
                  ORDER BY "price_snapshots"."scraped_at" DESC
                 LIMIT 1))
          ORDER BY "ps"."product_id", "ps"."scraped_at" DESC
        )
 SELECT "p"."id",
    "p"."name",
    "p"."source",
    "p"."ean",
    "p"."product_url",
    COALESCE("p"."image_url",
        CASE
            WHEN ("p"."images_all" IS NOT NULL) THEN ("p"."images_all" ->> 0)
            ELSE NULL::"text"
        END) AS "image_url",
    "p"."brand",
    "p"."in_stock",
    "lp"."current_price",
    "pp"."previous_price",
    "round"(((("pp"."previous_price" - "lp"."current_price") / "pp"."previous_price") * (100)::numeric), 2) AS "drop_percent",
    "round"(("pp"."previous_price" - "lp"."current_price"), 2) AS "savings_amount",
    "lp"."current_date",
    "pp"."previous_date"
   FROM (("public"."products" "p"
     JOIN "latest_prices" "lp" ON (("p"."id" = "lp"."product_id")))
     JOIN "previous_prices" "pp" ON (("p"."id" = "pp"."product_id")))
  WHERE (("pp"."previous_price" > "lp"."current_price") AND ("lp"."current_price" > (0)::numeric) AND ("pp"."previous_price" > (0)::numeric))
  ORDER BY ("round"(((("pp"."previous_price" - "lp"."current_price") / "pp"."previous_price") * (100)::numeric), 2)) DESC;


ALTER VIEW "public"."v_price_drops" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_products_current_enriched" AS
 SELECT "p"."id",
    "p"."name",
    "p"."source",
    "p"."product_url",
    "p"."ean",
    "p"."brand",
    "p"."brand" AS "brand_name",
    "p"."in_stock",
    "p"."image_url",
    "p"."created_at",
    "p"."updated_at",
    "p"."price" AS "lot_price",
    COALESCE("pr"."pack_quantity", 1) AS "pack_quantity",
        CASE
            WHEN (COALESCE("pr"."pack_quantity", 1) > 1) THEN ("p"."price" / (COALESCE("pr"."pack_quantity", 1))::numeric)
            ELSE "p"."price"
        END AS "unit_price"
   FROM ("public"."mv_products_current" "p"
     JOIN "public"."products" "pr" ON (("pr"."id" = "p"."id")));


ALTER VIEW "public"."v_products_current_enriched" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_products_full" AS
 SELECT "id",
    "name",
    "source",
    "category",
    "subcategory",
    "image_url",
    "product_url",
    "ean",
    "brand_name",
    "brand",
    "in_stock",
    "created_at",
    "updated_at",
    COALESCE(( SELECT "ps"."price_current"
           FROM "public"."price_snapshots" "ps"
          WHERE ("ps"."product_id" = "p"."id")
          ORDER BY "ps"."scraped_at" DESC
         LIMIT 1), "price") AS "price",
    COALESCE("image_url",
        CASE
            WHEN (("images_all" IS NOT NULL) AND ("jsonb_array_length"("images_all") > 0)) THEN ("images_all" ->> 0)
            ELSE NULL::"text"
        END) AS "image_url_fixed"
   FROM "public"."products" "p";


ALTER VIEW "public"."v_products_full" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_products_mr_ready" AS
 SELECT "id",
    "geizhals_id",
    "name",
    "category",
    "subcategory",
    "image_url",
    "product_url",
    "ean",
    "is_brand_flagged",
    "brand_name",
    "created_at",
    "updated_at",
    "weight_kg",
    "dimensions",
    "enriched_at",
    "subsubcategory",
    "mpn",
    "specs",
    "images_all",
    "variants",
    "source",
    "lefeld_id",
    "lefeld_article_id",
    "amazon_asin",
    "ebay_item_id",
    "idealo_id",
    "is_occasion",
    "bauhaus_id",
    "category_path",
    "comparable_products",
    "recommended_products",
    "name_fr",
    "category_path_fr",
    "specs_fr",
    "translated_at",
    "variant_group_id",
    "datasheets",
    "variants_fr",
    "datasheets_r2",
    "datasheets_fr_r2",
    "mr_compatible",
    "mr_weight_kg",
    "mr_max_dim_cm"
   FROM "public"."products"
  WHERE (("source" = 'bauhaus'::"text") AND ("mr_compatible" = true) AND ("name_fr" IS NOT NULL) AND ("image_url" IS NOT NULL));


ALTER VIEW "public"."v_products_mr_ready" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."view_configuration" (
    "id" "text" NOT NULL,
    "entity" "text" NOT NULL,
    "name" "text",
    "user_id" "text",
    "is_system_default" boolean DEFAULT false NOT NULL,
    "configuration" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."view_configuration" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."workflow_execution" (
    "id" character varying NOT NULL,
    "workflow_id" character varying NOT NULL,
    "transaction_id" character varying NOT NULL,
    "execution" "jsonb",
    "context" "jsonb",
    "state" character varying NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp without time zone,
    "retention_time" integer,
    "run_id" "text" DEFAULT '01KRTYB3JJK8V95YPEE6YEAC73'::"text" NOT NULL
);


ALTER TABLE "public"."workflow_execution" OWNER TO "postgres";


ALTER TABLE ONLY "public"."link_module_migrations" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."link_module_migrations_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."mikro_orm_migrations" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."mikro_orm_migrations_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."order" ALTER COLUMN "display_id" SET DEFAULT "nextval"('"public"."order_display_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."order_change_action" ALTER COLUMN "ordering" SET DEFAULT "nextval"('"public"."order_change_action_ordering_seq"'::"regclass");



ALTER TABLE ONLY "public"."order_claim" ALTER COLUMN "display_id" SET DEFAULT "nextval"('"public"."order_claim_display_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."order_exchange" ALTER COLUMN "display_id" SET DEFAULT "nextval"('"public"."order_exchange_display_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."price_history" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."price_history_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."refurbished_products" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."refurbished_products_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."return" ALTER COLUMN "display_id" SET DEFAULT "nextval"('"public"."return_display_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."scrape_queue" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."scrape_queue_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."script_migrations" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."script_migrations_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."account_holder"
    ADD CONSTRAINT "account_holder_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."api_key"
    ADD CONSTRAINT "api_key_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."application_method_buy_rules"
    ADD CONSTRAINT "application_method_buy_rules_pkey" PRIMARY KEY ("application_method_id", "promotion_rule_id");



ALTER TABLE ONLY "public"."application_method_target_rules"
    ADD CONSTRAINT "application_method_target_rules_pkey" PRIMARY KEY ("application_method_id", "promotion_rule_id");



ALTER TABLE ONLY "public"."auth_identity"
    ADD CONSTRAINT "auth_identity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bauportal_products"
    ADD CONSTRAINT "bauportal_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."brand_blacklist"
    ADD CONSTRAINT "brand_blacklist_brand_key" UNIQUE ("brand");



ALTER TABLE ONLY "public"."brand_blacklist"
    ADD CONSTRAINT "brand_blacklist_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."capture"
    ADD CONSTRAINT "capture_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cart_address"
    ADD CONSTRAINT "cart_address_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cart_line_item_adjustment"
    ADD CONSTRAINT "cart_line_item_adjustment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cart_line_item"
    ADD CONSTRAINT "cart_line_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cart_line_item_tax_line"
    ADD CONSTRAINT "cart_line_item_tax_line_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cart_payment_collection"
    ADD CONSTRAINT "cart_payment_collection_pkey" PRIMARY KEY ("cart_id", "payment_collection_id");



ALTER TABLE ONLY "public"."cart"
    ADD CONSTRAINT "cart_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cart_promotion"
    ADD CONSTRAINT "cart_promotion_pkey" PRIMARY KEY ("cart_id", "promotion_id");



ALTER TABLE ONLY "public"."cart_shipping_method_adjustment"
    ADD CONSTRAINT "cart_shipping_method_adjustment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cart_shipping_method"
    ADD CONSTRAINT "cart_shipping_method_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cart_shipping_method_tax_line"
    ADD CONSTRAINT "cart_shipping_method_tax_line_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."contorion_products"
    ADD CONSTRAINT "contorion_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."contorion_products"
    ADD CONSTRAINT "contorion_products_product_url_key" UNIQUE ("product_url");



ALTER TABLE ONLY "public"."credit_line"
    ADD CONSTRAINT "credit_line_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."currency"
    ADD CONSTRAINT "currency_pkey" PRIMARY KEY ("code");



ALTER TABLE ONLY "public"."customer_account_holder"
    ADD CONSTRAINT "customer_account_holder_pkey" PRIMARY KEY ("customer_id", "account_holder_id");



ALTER TABLE ONLY "public"."customer_address"
    ADD CONSTRAINT "customer_address_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_group_customer"
    ADD CONSTRAINT "customer_group_customer_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_group"
    ADD CONSTRAINT "customer_group_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer"
    ADD CONSTRAINT "customer_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."deals_ean_blacklist"
    ADD CONSTRAINT "deals_ean_blacklist_pkey" PRIMARY KEY ("ean");



ALTER TABLE ONLY "public"."fr_price_comparisons"
    ADD CONSTRAINT "fr_price_comparisons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fulfillment_address"
    ADD CONSTRAINT "fulfillment_address_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fulfillment_item"
    ADD CONSTRAINT "fulfillment_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fulfillment_label"
    ADD CONSTRAINT "fulfillment_label_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fulfillment"
    ADD CONSTRAINT "fulfillment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fulfillment_provider"
    ADD CONSTRAINT "fulfillment_provider_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fulfillment_set"
    ADD CONSTRAINT "fulfillment_set_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."geo_zone"
    ADD CONSTRAINT "geo_zone_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hardware_online_products"
    ADD CONSTRAINT "hardware_online_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hardware_online_products"
    ADD CONSTRAINT "hardware_online_products_sku_key" UNIQUE ("sku");



ALTER TABLE ONLY "public"."image"
    ADD CONSTRAINT "image_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_item"
    ADD CONSTRAINT "inventory_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_level"
    ADD CONSTRAINT "inventory_level_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invite"
    ADD CONSTRAINT "invite_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invite_rbac_role"
    ADD CONSTRAINT "invite_rbac_role_pkey" PRIMARY KEY ("invite_id", "rbac_role_id");



ALTER TABLE ONLY "public"."link_module_migrations"
    ADD CONSTRAINT "link_module_migrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."link_module_migrations"
    ADD CONSTRAINT "link_module_migrations_table_name_key" UNIQUE ("table_name");



ALTER TABLE ONLY "public"."location_fulfillment_provider"
    ADD CONSTRAINT "location_fulfillment_provider_pkey" PRIMARY KEY ("stock_location_id", "fulfillment_provider_id");



ALTER TABLE ONLY "public"."location_fulfillment_set"
    ADD CONSTRAINT "location_fulfillment_set_pkey" PRIMARY KEY ("stock_location_id", "fulfillment_set_id");



ALTER TABLE ONLY "public"."mikro_orm_migrations"
    ADD CONSTRAINT "mikro_orm_migrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mr_keyword_blacklist"
    ADD CONSTRAINT "mr_keyword_blacklist_pkey" PRIMARY KEY ("keyword");



ALTER TABLE ONLY "public"."notification"
    ADD CONSTRAINT "notification_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_provider"
    ADD CONSTRAINT "notification_provider_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_address"
    ADD CONSTRAINT "order_address_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_cart"
    ADD CONSTRAINT "order_cart_pkey" PRIMARY KEY ("order_id", "cart_id");



ALTER TABLE ONLY "public"."order_change_action"
    ADD CONSTRAINT "order_change_action_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_change"
    ADD CONSTRAINT "order_change_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_claim_item_image"
    ADD CONSTRAINT "order_claim_item_image_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_claim_item"
    ADD CONSTRAINT "order_claim_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_claim"
    ADD CONSTRAINT "order_claim_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_credit_line"
    ADD CONSTRAINT "order_credit_line_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_exchange_item"
    ADD CONSTRAINT "order_exchange_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_exchange"
    ADD CONSTRAINT "order_exchange_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_fulfillment"
    ADD CONSTRAINT "order_fulfillment_pkey" PRIMARY KEY ("order_id", "fulfillment_id");



ALTER TABLE ONLY "public"."order_item"
    ADD CONSTRAINT "order_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_line_item_adjustment"
    ADD CONSTRAINT "order_line_item_adjustment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_line_item"
    ADD CONSTRAINT "order_line_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_line_item_tax_line"
    ADD CONSTRAINT "order_line_item_tax_line_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_payment_collection"
    ADD CONSTRAINT "order_payment_collection_pkey" PRIMARY KEY ("order_id", "payment_collection_id");



ALTER TABLE ONLY "public"."order"
    ADD CONSTRAINT "order_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_promotion"
    ADD CONSTRAINT "order_promotion_pkey" PRIMARY KEY ("order_id", "promotion_id");



ALTER TABLE ONLY "public"."order_shipping_method_adjustment"
    ADD CONSTRAINT "order_shipping_method_adjustment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_shipping_method"
    ADD CONSTRAINT "order_shipping_method_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_shipping_method_tax_line"
    ADD CONSTRAINT "order_shipping_method_tax_line_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_shipping"
    ADD CONSTRAINT "order_shipping_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_summary"
    ADD CONSTRAINT "order_summary_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_transaction"
    ADD CONSTRAINT "order_transaction_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_collection_payment_providers"
    ADD CONSTRAINT "payment_collection_payment_providers_pkey" PRIMARY KEY ("payment_collection_id", "payment_provider_id");



ALTER TABLE ONLY "public"."payment_collection"
    ADD CONSTRAINT "payment_collection_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment"
    ADD CONSTRAINT "payment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_provider"
    ADD CONSTRAINT "payment_provider_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_session"
    ADD CONSTRAINT "payment_session_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_history"
    ADD CONSTRAINT "price_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_list"
    ADD CONSTRAINT "price_list_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_list_rule"
    ADD CONSTRAINT "price_list_rule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price"
    ADD CONSTRAINT "price_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_preference"
    ADD CONSTRAINT "price_preference_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_rule"
    ADD CONSTRAINT "price_rule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_set"
    ADD CONSTRAINT "price_set_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_snapshots"
    ADD CONSTRAINT "price_snapshots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_category"
    ADD CONSTRAINT "product_category_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_category_product"
    ADD CONSTRAINT "product_category_product_pkey" PRIMARY KEY ("product_id", "product_category_id");



ALTER TABLE ONLY "public"."product_collection"
    ADD CONSTRAINT "product_collection_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_option"
    ADD CONSTRAINT "product_option_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_option_value"
    ADD CONSTRAINT "product_option_value_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product"
    ADD CONSTRAINT "product_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_sales_channel"
    ADD CONSTRAINT "product_sales_channel_pkey" PRIMARY KEY ("product_id", "sales_channel_id");



ALTER TABLE ONLY "public"."product_shipping_profile"
    ADD CONSTRAINT "product_shipping_profile_pkey" PRIMARY KEY ("product_id", "shipping_profile_id");



ALTER TABLE ONLY "public"."product_tag"
    ADD CONSTRAINT "product_tag_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_tags"
    ADD CONSTRAINT "product_tags_pkey" PRIMARY KEY ("product_id", "product_tag_id");



ALTER TABLE ONLY "public"."product_type"
    ADD CONSTRAINT "product_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_variant_inventory_item"
    ADD CONSTRAINT "product_variant_inventory_item_pkey" PRIMARY KEY ("variant_id", "inventory_item_id");



ALTER TABLE ONLY "public"."product_variant_option"
    ADD CONSTRAINT "product_variant_option_pkey" PRIMARY KEY ("variant_id", "option_value_id");



ALTER TABLE ONLY "public"."product_variant"
    ADD CONSTRAINT "product_variant_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_variant_price_set"
    ADD CONSTRAINT "product_variant_price_set_pkey" PRIMARY KEY ("variant_id", "price_set_id");



ALTER TABLE ONLY "public"."product_variant_product_image"
    ADD CONSTRAINT "product_variant_product_image_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_geizhals_id_key" UNIQUE ("geizhals_id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."products_to_translate"
    ADD CONSTRAINT "products_to_translate_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_voelkner_id_unique" UNIQUE ("voelkner_id");



ALTER TABLE ONLY "public"."promotion_application_method"
    ADD CONSTRAINT "promotion_application_method_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promotion_campaign_budget"
    ADD CONSTRAINT "promotion_campaign_budget_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promotion_campaign_budget_usage"
    ADD CONSTRAINT "promotion_campaign_budget_usage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promotion_campaign"
    ADD CONSTRAINT "promotion_campaign_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promotion"
    ADD CONSTRAINT "promotion_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promotion_promotion_rule"
    ADD CONSTRAINT "promotion_promotion_rule_pkey" PRIMARY KEY ("promotion_id", "promotion_rule_id");



ALTER TABLE ONLY "public"."promotion_rule"
    ADD CONSTRAINT "promotion_rule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promotion_rule_value"
    ADD CONSTRAINT "promotion_rule_value_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."property_label"
    ADD CONSTRAINT "property_label_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."provider_identity"
    ADD CONSTRAINT "provider_identity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."publishable_api_key_sales_channel"
    ADD CONSTRAINT "publishable_api_key_sales_channel_pkey" PRIMARY KEY ("publishable_key_id", "sales_channel_id");



ALTER TABLE ONLY "public"."refund"
    ADD CONSTRAINT "refund_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."refund_reason"
    ADD CONSTRAINT "refund_reason_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."refurbished_products"
    ADD CONSTRAINT "refurbished_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."refurbished_products"
    ADD CONSTRAINT "refurbished_products_source_sku_key" UNIQUE ("source", "sku");



ALTER TABLE ONLY "public"."region_country"
    ADD CONSTRAINT "region_country_pkey" PRIMARY KEY ("iso_2");



ALTER TABLE ONLY "public"."region_payment_provider"
    ADD CONSTRAINT "region_payment_provider_pkey" PRIMARY KEY ("region_id", "payment_provider_id");



ALTER TABLE ONLY "public"."region"
    ADD CONSTRAINT "region_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reservation_item"
    ADD CONSTRAINT "reservation_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."return_fulfillment"
    ADD CONSTRAINT "return_fulfillment_pkey" PRIMARY KEY ("return_id", "fulfillment_id");



ALTER TABLE ONLY "public"."return_item"
    ADD CONSTRAINT "return_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."return"
    ADD CONSTRAINT "return_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."return_reason"
    ADD CONSTRAINT "return_reason_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_channel"
    ADD CONSTRAINT "sales_channel_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_channel_stock_location"
    ADD CONSTRAINT "sales_channel_stock_location_pkey" PRIMARY KEY ("sales_channel_id", "stock_location_id");



ALTER TABLE ONLY "public"."scrape_queue"
    ADD CONSTRAINT "scrape_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scrape_queue"
    ADD CONSTRAINT "scrape_queue_url_key" UNIQUE ("url");



ALTER TABLE ONLY "public"."scraper_status"
    ADD CONSTRAINT "scraper_status_pkey" PRIMARY KEY ("source");



ALTER TABLE ONLY "public"."scraping_logs"
    ADD CONSTRAINT "scraping_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."script_migrations"
    ADD CONSTRAINT "script_migrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."secondbuy_products"
    ADD CONSTRAINT "secondbuy_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."secondbuy_products"
    ADD CONSTRAINT "secondbuy_products_sku_key" UNIQUE ("sku");



ALTER TABLE ONLY "public"."secondbuy_stock_history"
    ADD CONSTRAINT "secondbuy_stock_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."service_zone"
    ADD CONSTRAINT "service_zone_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shipping_option"
    ADD CONSTRAINT "shipping_option_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shipping_option_price_set"
    ADD CONSTRAINT "shipping_option_price_set_pkey" PRIMARY KEY ("shipping_option_id", "price_set_id");



ALTER TABLE ONLY "public"."shipping_option_rule"
    ADD CONSTRAINT "shipping_option_rule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shipping_option_type"
    ADD CONSTRAINT "shipping_option_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shipping_profile"
    ADD CONSTRAINT "shipping_profile_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock_location_address"
    ADD CONSTRAINT "stock_location_address_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock_location"
    ADD CONSTRAINT "stock_location_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."store_currency"
    ADD CONSTRAINT "store_currency_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."store_locale"
    ADD CONSTRAINT "store_locale_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."store"
    ADD CONSTRAINT "store_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tax_provider"
    ADD CONSTRAINT "tax_provider_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tax_rate"
    ADD CONSTRAINT "tax_rate_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tax_rate_rule"
    ADD CONSTRAINT "tax_rate_rule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tax_region"
    ADD CONSTRAINT "tax_region_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."technikdirekt_products"
    ADD CONSTRAINT "technikdirekt_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user"
    ADD CONSTRAINT "user_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_preference"
    ADD CONSTRAINT "user_preference_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_rbac_role"
    ADD CONSTRAINT "user_rbac_role_pkey" PRIMARY KEY ("user_id", "rbac_role_id");



ALTER TABLE ONLY "public"."view_configuration"
    ADD CONSTRAINT "view_configuration_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workflow_execution"
    ADD CONSTRAINT "workflow_execution_pkey" PRIMARY KEY ("workflow_id", "transaction_id", "run_id");



CREATE INDEX "IDX_account_holder_deleted_at" ON "public"."account_holder" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_account_holder_id_5cb3a0c0" ON "public"."customer_account_holder" USING "btree" ("account_holder_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_account_holder_provider_id_external_id_unique" ON "public"."account_holder" USING "btree" ("provider_id", "external_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_api_key_deleted_at" ON "public"."api_key" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_api_key_redacted" ON "public"."api_key" USING "btree" ("redacted") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_api_key_revoked_at" ON "public"."api_key" USING "btree" ("revoked_at") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_api_key_token_unique" ON "public"."api_key" USING "btree" ("token");



CREATE INDEX "IDX_api_key_type" ON "public"."api_key" USING "btree" ("type");



CREATE INDEX "IDX_application_method_allocation" ON "public"."promotion_application_method" USING "btree" ("allocation");



CREATE INDEX "IDX_application_method_target_type" ON "public"."promotion_application_method" USING "btree" ("target_type");



CREATE INDEX "IDX_application_method_type" ON "public"."promotion_application_method" USING "btree" ("type");



CREATE INDEX "IDX_auth_identity_deleted_at" ON "public"."auth_identity" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_campaign_budget_type" ON "public"."promotion_campaign_budget" USING "btree" ("type");



CREATE INDEX "IDX_capture_deleted_at" ON "public"."capture" USING "btree" ("deleted_at");



CREATE INDEX "IDX_capture_payment_id" ON "public"."capture" USING "btree" ("payment_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_cart_address_deleted_at" ON "public"."cart_address" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_cart_billing_address_id" ON "public"."cart" USING "btree" ("billing_address_id") WHERE (("deleted_at" IS NULL) AND ("billing_address_id" IS NOT NULL));



CREATE INDEX "IDX_cart_credit_line_reference_reference_id" ON "public"."credit_line" USING "btree" ("reference", "reference_id") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_cart_currency_code" ON "public"."cart" USING "btree" ("currency_code");



CREATE INDEX "IDX_cart_customer_id" ON "public"."cart" USING "btree" ("customer_id") WHERE (("deleted_at" IS NULL) AND ("customer_id" IS NOT NULL));



CREATE INDEX "IDX_cart_deleted_at" ON "public"."cart" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_cart_id_-4a39f6c9" ON "public"."cart_payment_collection" USING "btree" ("cart_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_cart_id_-71069c16" ON "public"."order_cart" USING "btree" ("cart_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_cart_id_-a9d4a70b" ON "public"."cart_promotion" USING "btree" ("cart_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_cart_line_item_adjustment_deleted_at" ON "public"."cart_line_item_adjustment" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_cart_line_item_adjustment_item_id" ON "public"."cart_line_item_adjustment" USING "btree" ("item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_cart_line_item_cart_id" ON "public"."cart_line_item" USING "btree" ("cart_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_cart_line_item_deleted_at" ON "public"."cart_line_item" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_cart_line_item_tax_line_deleted_at" ON "public"."cart_line_item_tax_line" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_cart_line_item_tax_line_item_id" ON "public"."cart_line_item_tax_line" USING "btree" ("item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_cart_region_id" ON "public"."cart" USING "btree" ("region_id") WHERE (("deleted_at" IS NULL) AND ("region_id" IS NOT NULL));



CREATE INDEX "IDX_cart_sales_channel_id" ON "public"."cart" USING "btree" ("sales_channel_id") WHERE (("deleted_at" IS NULL) AND ("sales_channel_id" IS NOT NULL));



CREATE INDEX "IDX_cart_shipping_address_id" ON "public"."cart" USING "btree" ("shipping_address_id") WHERE (("deleted_at" IS NULL) AND ("shipping_address_id" IS NOT NULL));



CREATE INDEX "IDX_cart_shipping_method_adjustment_deleted_at" ON "public"."cart_shipping_method_adjustment" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_cart_shipping_method_adjustment_shipping_method_id" ON "public"."cart_shipping_method_adjustment" USING "btree" ("shipping_method_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_cart_shipping_method_cart_id" ON "public"."cart_shipping_method" USING "btree" ("cart_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_cart_shipping_method_deleted_at" ON "public"."cart_shipping_method" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_cart_shipping_method_tax_line_deleted_at" ON "public"."cart_shipping_method_tax_line" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_cart_shipping_method_tax_line_shipping_method_id" ON "public"."cart_shipping_method_tax_line" USING "btree" ("shipping_method_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_category_handle_unique" ON "public"."product_category" USING "btree" ("handle") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_collection_handle_unique" ON "public"."product_collection" USING "btree" ("handle") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_credit_line_cart_id" ON "public"."credit_line" USING "btree" ("cart_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_credit_line_deleted_at" ON "public"."credit_line" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_customer_address_customer_id" ON "public"."customer_address" USING "btree" ("customer_id");



CREATE INDEX "IDX_customer_address_deleted_at" ON "public"."customer_address" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_customer_address_unique_customer_billing" ON "public"."customer_address" USING "btree" ("customer_id") WHERE ("is_default_billing" = true);



CREATE UNIQUE INDEX "IDX_customer_address_unique_customer_shipping" ON "public"."customer_address" USING "btree" ("customer_id") WHERE ("is_default_shipping" = true);



CREATE INDEX "IDX_customer_deleted_at" ON "public"."customer" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_customer_email_has_account_unique" ON "public"."customer" USING "btree" ("email", "has_account") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_customer_group_customer_customer_group_id" ON "public"."customer_group_customer" USING "btree" ("customer_group_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_customer_group_customer_customer_id" ON "public"."customer_group_customer" USING "btree" ("customer_id");



CREATE INDEX "IDX_customer_group_customer_deleted_at" ON "public"."customer_group_customer" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_customer_group_deleted_at" ON "public"."customer_group" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_customer_group_name_unique" ON "public"."customer_group" USING "btree" ("name") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_customer_id_5cb3a0c0" ON "public"."customer_account_holder" USING "btree" ("customer_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_deleted_at_-1d67bae40" ON "public"."publishable_api_key_sales_channel" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_-1e5992737" ON "public"."location_fulfillment_provider" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_-31ea43a" ON "public"."return_fulfillment" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_-4a39f6c9" ON "public"."cart_payment_collection" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_-71069c16" ON "public"."order_cart" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_-71518339" ON "public"."order_promotion" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_-85069d44" ON "public"."invite_rbac_role" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_-a9d4a70b" ON "public"."cart_promotion" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_-e88adb96" ON "public"."location_fulfillment_set" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_-e8d2543e" ON "public"."order_fulfillment" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_17a262437" ON "public"."product_shipping_profile" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_17b4c4e35" ON "public"."product_variant_inventory_item" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_1c934dab0" ON "public"."region_payment_provider" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_20b454295" ON "public"."product_sales_channel" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_26d06f470" ON "public"."sales_channel_stock_location" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_52b23597" ON "public"."product_variant_price_set" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_5cb3a0c0" ON "public"."customer_account_holder" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_64ff0c4c" ON "public"."user_rbac_role" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_ba32fa9c" ON "public"."shipping_option_price_set" USING "btree" ("deleted_at");



CREATE INDEX "IDX_deleted_at_f42b9949" ON "public"."order_payment_collection" USING "btree" ("deleted_at");



CREATE INDEX "IDX_fulfillment_address_deleted_at" ON "public"."fulfillment_address" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_fulfillment_deleted_at" ON "public"."fulfillment" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_fulfillment_id_-31ea43a" ON "public"."return_fulfillment" USING "btree" ("fulfillment_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_id_-e8d2543e" ON "public"."order_fulfillment" USING "btree" ("fulfillment_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_item_deleted_at" ON "public"."fulfillment_item" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_fulfillment_item_fulfillment_id" ON "public"."fulfillment_item" USING "btree" ("fulfillment_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_item_inventory_item_id" ON "public"."fulfillment_item" USING "btree" ("inventory_item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_item_line_item_id" ON "public"."fulfillment_item" USING "btree" ("line_item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_label_deleted_at" ON "public"."fulfillment_label" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_fulfillment_label_fulfillment_id" ON "public"."fulfillment_label" USING "btree" ("fulfillment_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_location_id" ON "public"."fulfillment" USING "btree" ("location_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_provider_deleted_at" ON "public"."fulfillment_provider" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_provider_id_-1e5992737" ON "public"."location_fulfillment_provider" USING "btree" ("fulfillment_provider_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_set_deleted_at" ON "public"."fulfillment_set" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_fulfillment_set_id_-e88adb96" ON "public"."location_fulfillment_set" USING "btree" ("fulfillment_set_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_fulfillment_set_name_unique" ON "public"."fulfillment_set" USING "btree" ("name") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_fulfillment_shipping_option_id" ON "public"."fulfillment" USING "btree" ("shipping_option_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_geo_zone_city" ON "public"."geo_zone" USING "btree" ("city") WHERE (("deleted_at" IS NULL) AND ("city" IS NOT NULL));



CREATE INDEX "IDX_geo_zone_country_code" ON "public"."geo_zone" USING "btree" ("country_code") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_geo_zone_deleted_at" ON "public"."geo_zone" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_geo_zone_province_code" ON "public"."geo_zone" USING "btree" ("province_code") WHERE (("deleted_at" IS NULL) AND ("province_code" IS NOT NULL));



CREATE INDEX "IDX_geo_zone_service_zone_id" ON "public"."geo_zone" USING "btree" ("service_zone_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_id_-1d67bae40" ON "public"."publishable_api_key_sales_channel" USING "btree" ("id");



CREATE INDEX "IDX_id_-1e5992737" ON "public"."location_fulfillment_provider" USING "btree" ("id");



CREATE INDEX "IDX_id_-31ea43a" ON "public"."return_fulfillment" USING "btree" ("id");



CREATE INDEX "IDX_id_-4a39f6c9" ON "public"."cart_payment_collection" USING "btree" ("id");



CREATE INDEX "IDX_id_-71069c16" ON "public"."order_cart" USING "btree" ("id");



CREATE INDEX "IDX_id_-71518339" ON "public"."order_promotion" USING "btree" ("id");



CREATE INDEX "IDX_id_-85069d44" ON "public"."invite_rbac_role" USING "btree" ("id");



CREATE INDEX "IDX_id_-a9d4a70b" ON "public"."cart_promotion" USING "btree" ("id");



CREATE INDEX "IDX_id_-e88adb96" ON "public"."location_fulfillment_set" USING "btree" ("id");



CREATE INDEX "IDX_id_-e8d2543e" ON "public"."order_fulfillment" USING "btree" ("id");



CREATE INDEX "IDX_id_17a262437" ON "public"."product_shipping_profile" USING "btree" ("id");



CREATE INDEX "IDX_id_17b4c4e35" ON "public"."product_variant_inventory_item" USING "btree" ("id");



CREATE INDEX "IDX_id_1c934dab0" ON "public"."region_payment_provider" USING "btree" ("id");



CREATE INDEX "IDX_id_20b454295" ON "public"."product_sales_channel" USING "btree" ("id");



CREATE INDEX "IDX_id_26d06f470" ON "public"."sales_channel_stock_location" USING "btree" ("id");



CREATE INDEX "IDX_id_52b23597" ON "public"."product_variant_price_set" USING "btree" ("id");



CREATE INDEX "IDX_id_5cb3a0c0" ON "public"."customer_account_holder" USING "btree" ("id");



CREATE INDEX "IDX_id_64ff0c4c" ON "public"."user_rbac_role" USING "btree" ("id");



CREATE INDEX "IDX_id_ba32fa9c" ON "public"."shipping_option_price_set" USING "btree" ("id");



CREATE INDEX "IDX_id_f42b9949" ON "public"."order_payment_collection" USING "btree" ("id");



CREATE INDEX "IDX_image_deleted_at" ON "public"."image" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_image_product_id" ON "public"."image" USING "btree" ("product_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_inventory_item_deleted_at" ON "public"."inventory_item" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_inventory_item_id_17b4c4e35" ON "public"."product_variant_inventory_item" USING "btree" ("inventory_item_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_inventory_item_sku" ON "public"."inventory_item" USING "btree" ("sku") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_inventory_level_deleted_at" ON "public"."inventory_level" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_inventory_level_inventory_item_id" ON "public"."inventory_level" USING "btree" ("inventory_item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_inventory_level_location_id" ON "public"."inventory_level" USING "btree" ("location_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_inventory_level_location_id_inventory_item_id" ON "public"."inventory_level" USING "btree" ("inventory_item_id", "location_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_invite_deleted_at" ON "public"."invite" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE UNIQUE INDEX "IDX_invite_email_unique" ON "public"."invite" USING "btree" ("email") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_invite_id_-85069d44" ON "public"."invite_rbac_role" USING "btree" ("invite_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_invite_token" ON "public"."invite" USING "btree" ("token") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_line_item_adjustment_promotion_id" ON "public"."cart_line_item_adjustment" USING "btree" ("promotion_id") WHERE (("deleted_at" IS NULL) AND ("promotion_id" IS NOT NULL));



CREATE INDEX "IDX_line_item_product_id" ON "public"."cart_line_item" USING "btree" ("product_id") WHERE (("deleted_at" IS NULL) AND ("product_id" IS NOT NULL));



CREATE INDEX "IDX_line_item_product_type_id" ON "public"."order_line_item" USING "btree" ("product_type_id") WHERE (("deleted_at" IS NULL) AND ("product_type_id" IS NOT NULL));



CREATE INDEX "IDX_line_item_tax_line_tax_rate_id" ON "public"."cart_line_item_tax_line" USING "btree" ("tax_rate_id") WHERE (("deleted_at" IS NULL) AND ("tax_rate_id" IS NOT NULL));



CREATE INDEX "IDX_line_item_variant_id" ON "public"."cart_line_item" USING "btree" ("variant_id") WHERE (("deleted_at" IS NULL) AND ("variant_id" IS NOT NULL));



CREATE INDEX "IDX_notification_deleted_at" ON "public"."notification" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_notification_idempotency_key_unique" ON "public"."notification" USING "btree" ("idempotency_key") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_notification_provider_deleted_at" ON "public"."notification_provider" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_notification_provider_id" ON "public"."notification" USING "btree" ("provider_id");



CREATE INDEX "IDX_notification_receiver_id" ON "public"."notification" USING "btree" ("receiver_id");



CREATE UNIQUE INDEX "IDX_option_product_id_title_unique" ON "public"."product_option" USING "btree" ("product_id", "title") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_option_value_option_id_unique" ON "public"."product_option_value" USING "btree" ("option_id", "value") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_address_customer_id" ON "public"."order_address" USING "btree" ("customer_id");



CREATE INDEX "IDX_order_address_deleted_at" ON "public"."order_address" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_billing_address_id" ON "public"."order" USING "btree" ("billing_address_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_change_action_claim_id" ON "public"."order_change_action" USING "btree" ("claim_id") WHERE (("claim_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_change_action_deleted_at" ON "public"."order_change_action" USING "btree" ("deleted_at");



CREATE INDEX "IDX_order_change_action_exchange_id" ON "public"."order_change_action" USING "btree" ("exchange_id") WHERE (("exchange_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_change_action_order_change_id" ON "public"."order_change_action" USING "btree" ("order_change_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_change_action_order_id" ON "public"."order_change_action" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_change_action_ordering" ON "public"."order_change_action" USING "btree" ("ordering") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_change_action_return_id" ON "public"."order_change_action" USING "btree" ("return_id") WHERE (("return_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_change_change_type" ON "public"."order_change" USING "btree" ("change_type");



CREATE INDEX "IDX_order_change_claim_id" ON "public"."order_change" USING "btree" ("claim_id") WHERE (("claim_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_change_deleted_at" ON "public"."order_change" USING "btree" ("deleted_at");



CREATE INDEX "IDX_order_change_exchange_id" ON "public"."order_change" USING "btree" ("exchange_id") WHERE (("exchange_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_change_order_id" ON "public"."order_change" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_change_order_id_version" ON "public"."order_change" USING "btree" ("order_id", "version");



CREATE INDEX "IDX_order_change_return_id" ON "public"."order_change" USING "btree" ("return_id") WHERE (("return_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_change_status" ON "public"."order_change" USING "btree" ("status") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_change_version" ON "public"."order_change" USING "btree" ("order_id", "version") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_claim_deleted_at" ON "public"."order_claim" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_claim_display_id" ON "public"."order_claim" USING "btree" ("display_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_claim_item_claim_id" ON "public"."order_claim_item" USING "btree" ("claim_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_claim_item_deleted_at" ON "public"."order_claim_item" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_claim_item_image_claim_item_id" ON "public"."order_claim_item_image" USING "btree" ("claim_item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_claim_item_image_deleted_at" ON "public"."order_claim_item_image" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_order_claim_item_item_id" ON "public"."order_claim_item" USING "btree" ("item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_claim_order_id" ON "public"."order_claim" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_claim_return_id" ON "public"."order_claim" USING "btree" ("return_id") WHERE (("return_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_credit_line_deleted_at" ON "public"."order_credit_line" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_order_credit_line_order_id" ON "public"."order_credit_line" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_credit_line_order_id_version" ON "public"."order_credit_line" USING "btree" ("order_id", "version") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_currency_code" ON "public"."order" USING "btree" ("currency_code") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_order_custom_display_id" ON "public"."order" USING "btree" ("custom_display_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_customer_id" ON "public"."order" USING "btree" ("customer_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_deleted_at" ON "public"."order" USING "btree" ("deleted_at");



CREATE INDEX "IDX_order_display_id" ON "public"."order" USING "btree" ("display_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_exchange_deleted_at" ON "public"."order_exchange" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_exchange_display_id" ON "public"."order_exchange" USING "btree" ("display_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_exchange_item_deleted_at" ON "public"."order_exchange_item" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_exchange_item_exchange_id" ON "public"."order_exchange_item" USING "btree" ("exchange_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_exchange_item_item_id" ON "public"."order_exchange_item" USING "btree" ("item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_exchange_order_id" ON "public"."order_exchange" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_exchange_return_id" ON "public"."order_exchange" USING "btree" ("return_id") WHERE (("return_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_id_-71069c16" ON "public"."order_cart" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_id_-71518339" ON "public"."order_promotion" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_id_-e8d2543e" ON "public"."order_fulfillment" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_id_f42b9949" ON "public"."order_payment_collection" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_is_draft_order" ON "public"."order" USING "btree" ("is_draft_order") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_item_deleted_at" ON "public"."order_item" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_order_item_item_id" ON "public"."order_item" USING "btree" ("item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_item_order_id" ON "public"."order_item" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_item_order_id_version" ON "public"."order_item" USING "btree" ("order_id", "version") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_line_item_adjustment_item_id" ON "public"."order_line_item_adjustment" USING "btree" ("item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_line_item_product_id" ON "public"."order_line_item" USING "btree" ("product_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_line_item_tax_line_item_id" ON "public"."order_line_item_tax_line" USING "btree" ("item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_line_item_variant_id" ON "public"."order_line_item" USING "btree" ("variant_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_region_id" ON "public"."order" USING "btree" ("region_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_sales_channel_id" ON "public"."order" USING "btree" ("sales_channel_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_shipping_address_id" ON "public"."order" USING "btree" ("shipping_address_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_shipping_claim_id" ON "public"."order_shipping" USING "btree" ("claim_id") WHERE (("claim_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_shipping_deleted_at" ON "public"."order_shipping" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_order_shipping_exchange_id" ON "public"."order_shipping" USING "btree" ("exchange_id") WHERE (("exchange_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_shipping_item_id" ON "public"."order_shipping" USING "btree" ("shipping_method_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_shipping_method_adjustment_shipping_method_id" ON "public"."order_shipping_method_adjustment" USING "btree" ("shipping_method_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_order_shipping_method_adjustment_version_shipping_method" ON "public"."order_shipping_method_adjustment" USING "btree" ("version", "shipping_method_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_shipping_method_shipping_option_id" ON "public"."order_shipping_method" USING "btree" ("shipping_option_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_shipping_method_tax_line_shipping_method_id" ON "public"."order_shipping_method_tax_line" USING "btree" ("shipping_method_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_shipping_order_id" ON "public"."order_shipping" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_shipping_order_id_version" ON "public"."order_shipping" USING "btree" ("order_id", "version") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_shipping_return_id" ON "public"."order_shipping" USING "btree" ("return_id") WHERE (("return_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_shipping_shipping_method_id" ON "public"."order_shipping" USING "btree" ("shipping_method_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_summary_deleted_at" ON "public"."order_summary" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_order_summary_order_id_version" ON "public"."order_summary" USING "btree" ("order_id", "version") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_transaction_claim_id" ON "public"."order_transaction" USING "btree" ("claim_id") WHERE (("claim_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_transaction_currency_code" ON "public"."order_transaction" USING "btree" ("currency_code") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_transaction_exchange_id" ON "public"."order_transaction" USING "btree" ("exchange_id") WHERE (("exchange_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_order_transaction_order_id" ON "public"."order_transaction" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_transaction_order_id_version" ON "public"."order_transaction" USING "btree" ("order_id", "version") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_transaction_reference_id" ON "public"."order_transaction" USING "btree" ("reference_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_order_transaction_return_id" ON "public"."order_transaction" USING "btree" ("return_id") WHERE (("return_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_payment_collection_deleted_at" ON "public"."payment_collection" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_payment_collection_id_-4a39f6c9" ON "public"."cart_payment_collection" USING "btree" ("payment_collection_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_payment_collection_id_f42b9949" ON "public"."order_payment_collection" USING "btree" ("payment_collection_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_payment_deleted_at" ON "public"."payment" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_payment_payment_collection_id" ON "public"."payment" USING "btree" ("payment_collection_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_payment_payment_session_id" ON "public"."payment" USING "btree" ("payment_session_id");



CREATE UNIQUE INDEX "IDX_payment_payment_session_id_unique" ON "public"."payment" USING "btree" ("payment_session_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_payment_provider_deleted_at" ON "public"."payment_provider" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_payment_provider_id" ON "public"."payment" USING "btree" ("provider_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_payment_provider_id_1c934dab0" ON "public"."region_payment_provider" USING "btree" ("payment_provider_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_payment_session_deleted_at" ON "public"."payment_session" USING "btree" ("deleted_at");



CREATE INDEX "IDX_payment_session_payment_collection_id" ON "public"."payment_session" USING "btree" ("payment_collection_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_currency_code" ON "public"."price" USING "btree" ("currency_code") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_deleted_at" ON "public"."price" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_price_list_deleted_at" ON "public"."price_list" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_price_list_id_status_starts_at_ends_at" ON "public"."price_list" USING "btree" ("id", "status", "starts_at", "ends_at") WHERE (("deleted_at" IS NULL) AND ("status" = 'active'::"text"));



CREATE INDEX "IDX_price_list_rule_attribute" ON "public"."price_list_rule" USING "btree" ("attribute") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_list_rule_deleted_at" ON "public"."price_list_rule" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_price_list_rule_price_list_id" ON "public"."price_list_rule" USING "btree" ("price_list_id") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_price_list_rule_value" ON "public"."price_list_rule" USING "gin" ("value") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_price_preference_attribute_value" ON "public"."price_preference" USING "btree" ("attribute", "value") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_preference_deleted_at" ON "public"."price_preference" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_price_price_list_id" ON "public"."price" USING "btree" ("price_list_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_price_set_id" ON "public"."price" USING "btree" ("price_set_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_rule_attribute" ON "public"."price_rule" USING "btree" ("attribute") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_rule_attribute_value" ON "public"."price_rule" USING "btree" ("attribute", "value") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_rule_attribute_value_price_id" ON "public"."price_rule" USING "btree" ("attribute", "value", "price_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_rule_deleted_at" ON "public"."price_rule" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_price_rule_operator" ON "public"."price_rule" USING "btree" ("operator");



CREATE INDEX "IDX_price_rule_operator_value" ON "public"."price_rule" USING "btree" ("operator", "value") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_rule_price_id" ON "public"."price_rule" USING "btree" ("price_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_price_rule_price_id_attribute_operator_unique" ON "public"."price_rule" USING "btree" ("price_id", "attribute", "operator") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_set_deleted_at" ON "public"."price_set" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_price_set_id_52b23597" ON "public"."product_variant_price_set" USING "btree" ("price_set_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_price_set_id_ba32fa9c" ON "public"."shipping_option_price_set" USING "btree" ("price_set_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_category_parent_category_id" ON "public"."product_category" USING "btree" ("parent_category_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_category_path" ON "public"."product_category" USING "btree" ("mpath") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_collection_deleted_at" ON "public"."product_collection" USING "btree" ("deleted_at");



CREATE INDEX "IDX_product_collection_id" ON "public"."product" USING "btree" ("collection_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_deleted_at" ON "public"."product" USING "btree" ("deleted_at");



CREATE UNIQUE INDEX "IDX_product_handle_unique" ON "public"."product" USING "btree" ("handle") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_id_17a262437" ON "public"."product_shipping_profile" USING "btree" ("product_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_id_20b454295" ON "public"."product_sales_channel" USING "btree" ("product_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_image_rank" ON "public"."image" USING "btree" ("rank") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_image_rank_product_id" ON "public"."image" USING "btree" ("rank", "product_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_image_url" ON "public"."image" USING "btree" ("url") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_image_url_rank_product_id" ON "public"."image" USING "btree" ("url", "rank", "product_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_option_deleted_at" ON "public"."product_option" USING "btree" ("deleted_at");



CREATE INDEX "IDX_product_option_product_id" ON "public"."product_option" USING "btree" ("product_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_option_value_deleted_at" ON "public"."product_option_value" USING "btree" ("deleted_at");



CREATE INDEX "IDX_product_option_value_option_id" ON "public"."product_option_value" USING "btree" ("option_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_status" ON "public"."product" USING "btree" ("status") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_tag_deleted_at" ON "public"."product_tag" USING "btree" ("deleted_at");



CREATE INDEX "IDX_product_type_deleted_at" ON "public"."product_type" USING "btree" ("deleted_at");



CREATE INDEX "IDX_product_type_id" ON "public"."product" USING "btree" ("type_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_product_variant_barcode_unique" ON "public"."product_variant" USING "btree" ("barcode") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_variant_deleted_at" ON "public"."product_variant" USING "btree" ("deleted_at");



CREATE UNIQUE INDEX "IDX_product_variant_ean_unique" ON "public"."product_variant" USING "btree" ("ean") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_variant_id_product_id" ON "public"."product_variant" USING "btree" ("id", "product_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_variant_product_id" ON "public"."product_variant" USING "btree" ("product_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_variant_product_image_deleted_at" ON "public"."product_variant_product_image" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_variant_product_image_image_id" ON "public"."product_variant_product_image" USING "btree" ("image_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_product_variant_product_image_variant_id" ON "public"."product_variant_product_image" USING "btree" ("variant_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_product_variant_sku_unique" ON "public"."product_variant" USING "btree" ("sku") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_product_variant_upc_unique" ON "public"."product_variant" USING "btree" ("upc") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_application_method_currency_code" ON "public"."promotion_application_method" USING "btree" ("currency_code") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_promotion_application_method_deleted_at" ON "public"."promotion_application_method" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_promotion_application_method_promotion_id_unique" ON "public"."promotion_application_method" USING "btree" ("promotion_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_promotion_campaign_budget_campaign_id_unique" ON "public"."promotion_campaign_budget" USING "btree" ("campaign_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_campaign_budget_deleted_at" ON "public"."promotion_campaign_budget" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_promotion_campaign_budget_usage_attribute_value_budget_id_u" ON "public"."promotion_campaign_budget_usage" USING "btree" ("attribute_value", "budget_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_campaign_budget_usage_budget_id" ON "public"."promotion_campaign_budget_usage" USING "btree" ("budget_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_campaign_budget_usage_deleted_at" ON "public"."promotion_campaign_budget_usage" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_promotion_campaign_campaign_identifier_unique" ON "public"."promotion_campaign" USING "btree" ("campaign_identifier") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_campaign_deleted_at" ON "public"."promotion_campaign" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_campaign_id" ON "public"."promotion" USING "btree" ("campaign_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_deleted_at" ON "public"."promotion" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_id_-71518339" ON "public"."order_promotion" USING "btree" ("promotion_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_id_-a9d4a70b" ON "public"."cart_promotion" USING "btree" ("promotion_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_is_automatic" ON "public"."promotion" USING "btree" ("is_automatic") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_rule_attribute" ON "public"."promotion_rule" USING "btree" ("attribute");



CREATE INDEX "IDX_promotion_rule_attribute_operator" ON "public"."promotion_rule" USING "btree" ("attribute", "operator") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_rule_attribute_operator_id" ON "public"."promotion_rule" USING "btree" ("operator", "attribute", "id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_rule_deleted_at" ON "public"."promotion_rule" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_rule_operator" ON "public"."promotion_rule" USING "btree" ("operator");



CREATE INDEX "IDX_promotion_rule_value_deleted_at" ON "public"."promotion_rule_value" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_rule_value_promotion_rule_id" ON "public"."promotion_rule_value" USING "btree" ("promotion_rule_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_rule_value_rule_id_value" ON "public"."promotion_rule_value" USING "btree" ("promotion_rule_id", "value") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_rule_value_value" ON "public"."promotion_rule_value" USING "btree" ("value") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_status" ON "public"."promotion" USING "btree" ("status") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_promotion_type" ON "public"."promotion" USING "btree" ("type");



CREATE INDEX "IDX_property_label_deleted_at" ON "public"."property_label" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_property_label_entity" ON "public"."property_label" USING "btree" ("entity") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_property_label_entity_property_unique" ON "public"."property_label" USING "btree" ("entity", "property") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_provider_identity_auth_identity_id" ON "public"."provider_identity" USING "btree" ("auth_identity_id");



CREATE INDEX "IDX_provider_identity_deleted_at" ON "public"."provider_identity" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_provider_identity_provider_entity_id" ON "public"."provider_identity" USING "btree" ("entity_id", "provider");



CREATE INDEX "IDX_publishable_key_id_-1d67bae40" ON "public"."publishable_api_key_sales_channel" USING "btree" ("publishable_key_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_rbac_role_id_-85069d44" ON "public"."invite_rbac_role" USING "btree" ("rbac_role_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_rbac_role_id_64ff0c4c" ON "public"."user_rbac_role" USING "btree" ("rbac_role_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_refund_deleted_at" ON "public"."refund" USING "btree" ("deleted_at");



CREATE INDEX "IDX_refund_payment_id" ON "public"."refund" USING "btree" ("payment_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_refund_reason_deleted_at" ON "public"."refund_reason" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_refund_refund_reason_id" ON "public"."refund" USING "btree" ("refund_reason_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_region_country_deleted_at" ON "public"."region_country" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_region_country_region_id" ON "public"."region_country" USING "btree" ("region_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_region_country_region_id_iso_2_unique" ON "public"."region_country" USING "btree" ("region_id", "iso_2");



CREATE INDEX "IDX_region_deleted_at" ON "public"."region" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_region_id_1c934dab0" ON "public"."region_payment_provider" USING "btree" ("region_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_reservation_item_deleted_at" ON "public"."reservation_item" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_reservation_item_inventory_item_id" ON "public"."reservation_item" USING "btree" ("inventory_item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_reservation_item_line_item_id" ON "public"."reservation_item" USING "btree" ("line_item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_reservation_item_location_id" ON "public"."reservation_item" USING "btree" ("location_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_return_claim_id" ON "public"."return" USING "btree" ("claim_id") WHERE (("claim_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_return_display_id" ON "public"."return" USING "btree" ("display_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_return_exchange_id" ON "public"."return" USING "btree" ("exchange_id") WHERE (("exchange_id" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_return_id_-31ea43a" ON "public"."return_fulfillment" USING "btree" ("return_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_return_item_deleted_at" ON "public"."return_item" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_return_item_item_id" ON "public"."return_item" USING "btree" ("item_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_return_item_reason_id" ON "public"."return_item" USING "btree" ("reason_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_return_item_return_id" ON "public"."return_item" USING "btree" ("return_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_return_order_id" ON "public"."return" USING "btree" ("order_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_return_reason_parent_return_reason_id" ON "public"."return_reason" USING "btree" ("parent_return_reason_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_return_reason_value" ON "public"."return_reason" USING "btree" ("value") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_sales_channel_deleted_at" ON "public"."sales_channel" USING "btree" ("deleted_at");



CREATE INDEX "IDX_sales_channel_id_-1d67bae40" ON "public"."publishable_api_key_sales_channel" USING "btree" ("sales_channel_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_sales_channel_id_20b454295" ON "public"."product_sales_channel" USING "btree" ("sales_channel_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_sales_channel_id_26d06f470" ON "public"."sales_channel_stock_location" USING "btree" ("sales_channel_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_service_zone_deleted_at" ON "public"."service_zone" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_service_zone_fulfillment_set_id" ON "public"."service_zone" USING "btree" ("fulfillment_set_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_service_zone_name_unique" ON "public"."service_zone" USING "btree" ("name") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_shipping_method_adjustment_promotion_id" ON "public"."cart_shipping_method_adjustment" USING "btree" ("promotion_id") WHERE (("deleted_at" IS NULL) AND ("promotion_id" IS NOT NULL));



CREATE INDEX "IDX_shipping_method_option_id" ON "public"."cart_shipping_method" USING "btree" ("shipping_option_id") WHERE (("deleted_at" IS NULL) AND ("shipping_option_id" IS NOT NULL));



CREATE INDEX "IDX_shipping_method_tax_line_tax_rate_id" ON "public"."cart_shipping_method_tax_line" USING "btree" ("tax_rate_id") WHERE (("deleted_at" IS NULL) AND ("tax_rate_id" IS NOT NULL));



CREATE INDEX "IDX_shipping_option_deleted_at" ON "public"."shipping_option" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_shipping_option_id_ba32fa9c" ON "public"."shipping_option_price_set" USING "btree" ("shipping_option_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_shipping_option_provider_id" ON "public"."shipping_option" USING "btree" ("provider_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_shipping_option_rule_deleted_at" ON "public"."shipping_option_rule" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_shipping_option_rule_shipping_option_id" ON "public"."shipping_option_rule" USING "btree" ("shipping_option_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_shipping_option_service_zone_id" ON "public"."shipping_option" USING "btree" ("service_zone_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_shipping_option_shipping_option_type_id" ON "public"."shipping_option" USING "btree" ("shipping_option_type_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_shipping_option_shipping_profile_id" ON "public"."shipping_option" USING "btree" ("shipping_profile_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_shipping_option_type_deleted_at" ON "public"."shipping_option_type" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_shipping_profile_deleted_at" ON "public"."shipping_profile" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_shipping_profile_id_17a262437" ON "public"."product_shipping_profile" USING "btree" ("shipping_profile_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_shipping_profile_name_unique" ON "public"."shipping_profile" USING "btree" ("name") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_single_default_region" ON "public"."tax_rate" USING "btree" ("tax_region_id") WHERE (("is_default" = true) AND ("deleted_at" IS NULL));



CREATE INDEX "IDX_stock_location_address_deleted_at" ON "public"."stock_location_address" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE UNIQUE INDEX "IDX_stock_location_address_id_unique" ON "public"."stock_location" USING "btree" ("address_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_stock_location_deleted_at" ON "public"."stock_location" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_stock_location_id_-1e5992737" ON "public"."location_fulfillment_provider" USING "btree" ("stock_location_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_stock_location_id_-e88adb96" ON "public"."location_fulfillment_set" USING "btree" ("stock_location_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_stock_location_id_26d06f470" ON "public"."sales_channel_stock_location" USING "btree" ("stock_location_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_store_currency_deleted_at" ON "public"."store_currency" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_store_currency_store_id" ON "public"."store_currency" USING "btree" ("store_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_store_deleted_at" ON "public"."store" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_store_locale_deleted_at" ON "public"."store_locale" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_store_locale_store_id" ON "public"."store_locale" USING "btree" ("store_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_tag_value_unique" ON "public"."product_tag" USING "btree" ("value") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_tax_provider_deleted_at" ON "public"."tax_provider" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_tax_rate_deleted_at" ON "public"."tax_rate" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_tax_rate_rule_deleted_at" ON "public"."tax_rate_rule" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_tax_rate_rule_reference_id" ON "public"."tax_rate_rule" USING "btree" ("reference_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_tax_rate_rule_tax_rate_id" ON "public"."tax_rate_rule" USING "btree" ("tax_rate_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_tax_rate_rule_unique_rate_reference" ON "public"."tax_rate_rule" USING "btree" ("tax_rate_id", "reference_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_tax_rate_tax_region_id" ON "public"."tax_rate" USING "btree" ("tax_region_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_tax_region_deleted_at" ON "public"."tax_region" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE INDEX "IDX_tax_region_parent_id" ON "public"."tax_region" USING "btree" ("parent_id");



CREATE INDEX "IDX_tax_region_provider_id" ON "public"."tax_region" USING "btree" ("provider_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_tax_region_unique_country_nullable_province" ON "public"."tax_region" USING "btree" ("country_code") WHERE (("province_code" IS NULL) AND ("deleted_at" IS NULL));



CREATE UNIQUE INDEX "IDX_tax_region_unique_country_province" ON "public"."tax_region" USING "btree" ("country_code", "province_code") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_type_value_unique" ON "public"."product_type" USING "btree" ("value") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_unique_promotion_code" ON "public"."promotion" USING "btree" ("code") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_user_deleted_at" ON "public"."user" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NOT NULL);



CREATE UNIQUE INDEX "IDX_user_email_unique" ON "public"."user" USING "btree" ("email") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_user_id_64ff0c4c" ON "public"."user_rbac_role" USING "btree" ("user_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_user_preference_deleted_at" ON "public"."user_preference" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_user_preference_user_id" ON "public"."user_preference" USING "btree" ("user_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_user_preference_user_id_key_unique" ON "public"."user_preference" USING "btree" ("user_id", "key") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_variant_id_17b4c4e35" ON "public"."product_variant_inventory_item" USING "btree" ("variant_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_variant_id_52b23597" ON "public"."product_variant_price_set" USING "btree" ("variant_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_view_configuration_deleted_at" ON "public"."view_configuration" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_view_configuration_entity_is_system_default" ON "public"."view_configuration" USING "btree" ("entity", "is_system_default") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_view_configuration_entity_user_id" ON "public"."view_configuration" USING "btree" ("entity", "user_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_view_configuration_user_id" ON "public"."view_configuration" USING "btree" ("user_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_workflow_execution_deleted_at" ON "public"."workflow_execution" USING "btree" ("deleted_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_workflow_execution_id" ON "public"."workflow_execution" USING "btree" ("id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_workflow_execution_retention_time_updated_at_state" ON "public"."workflow_execution" USING "btree" ("retention_time", "updated_at", "state") WHERE (("deleted_at" IS NULL) AND ("retention_time" IS NOT NULL));



CREATE INDEX "IDX_workflow_execution_run_id" ON "public"."workflow_execution" USING "btree" ("run_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_workflow_execution_state" ON "public"."workflow_execution" USING "btree" ("state") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_workflow_execution_state_updated_at" ON "public"."workflow_execution" USING "btree" ("state", "updated_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_workflow_execution_transaction_id" ON "public"."workflow_execution" USING "btree" ("transaction_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_workflow_execution_updated_at_retention_time" ON "public"."workflow_execution" USING "btree" ("updated_at", "retention_time") WHERE (("deleted_at" IS NULL) AND ("retention_time" IS NOT NULL) AND (("state")::"text" = ANY ((ARRAY['done'::character varying, 'failed'::character varying, 'reverted'::character varying])::"text"[])));



CREATE INDEX "IDX_workflow_execution_workflow_id" ON "public"."workflow_execution" USING "btree" ("workflow_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "IDX_workflow_execution_workflow_id_transaction_id" ON "public"."workflow_execution" USING "btree" ("workflow_id", "transaction_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "IDX_workflow_execution_workflow_id_transaction_id_run_id_unique" ON "public"."workflow_execution" USING "btree" ("workflow_id", "transaction_id", "run_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "bauportal_products_ean_idx" ON "public"."bauportal_products" USING "btree" ("ean") WHERE ("ean" IS NOT NULL);



CREATE INDEX "bauportal_products_ean_price_id_idx" ON "public"."bauportal_products" USING "btree" ("ean", "price", "id") WHERE (("ean" IS NOT NULL) AND ("ean" <> ''::"text"));



CREATE UNIQUE INDEX "bauportal_products_product_url_uidx" ON "public"."bauportal_products" USING "btree" ("product_url");



CREATE INDEX "bauportal_products_scraped_at_idx" ON "public"."bauportal_products" USING "btree" ("scraped_at" DESC);



CREATE INDEX "bauportal_products_source_idx" ON "public"."bauportal_products" USING "btree" ("source");



CREATE INDEX "bauportal_products_updated_at_idx" ON "public"."bauportal_products" USING "btree" ("updated_at" DESC);



CREATE INDEX "deals_ean_blacklist_ean_idx" ON "public"."deals_ean_blacklist" USING "btree" ("ean");



CREATE UNIQUE INDEX "deals_ean_blacklist_ean_uidx" ON "public"."deals_ean_blacklist" USING "btree" ("ean");



CREATE INDEX "idx_bauportal_products_search_fts" ON "public"."bauportal_products" USING "gin" ("to_tsvector"('"simple"'::"regconfig", "public"."normalize_search_de"(((COALESCE("name", ''::"text") || ' '::"text") || COALESCE("ean", ''::"text")))));



CREATE INDEX "idx_contorion_products_brand" ON "public"."contorion_products" USING "btree" ("brand");



CREATE INDEX "idx_contorion_products_ean" ON "public"."contorion_products" USING "btree" ("ean");



CREATE INDEX "idx_contorion_products_price" ON "public"."contorion_products" USING "btree" ("price");



CREATE INDEX "idx_contorion_products_scraped_at" ON "public"."contorion_products" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_contorion_products_sku" ON "public"."contorion_products" USING "btree" ("sku");



CREATE INDEX "idx_deals_ean_blacklist_created_at" ON "public"."deals_ean_blacklist" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_deals_fast" ON "public"."products" USING "btree" ("ean", "source", "price", "in_stock") WHERE (("ean" IS NOT NULL) AND ("price" > (0)::numeric) AND ("price" >= (5)::numeric) AND ("in_stock" = true));



CREATE INDEX "idx_fr_comparisons_product" ON "public"."fr_price_comparisons" USING "btree" ("product_id");



CREATE INDEX "idx_multi_source_eans" ON "public"."multi_source_eans" USING "btree" ("ean");



CREATE UNIQUE INDEX "idx_multi_source_eans_ean_unique" ON "public"."multi_source_eans" USING "btree" ("ean");



CREATE INDEX "idx_mv_bauhaus_blacklist_ean" ON "public"."mv_bauhaus_blacklist_eans" USING "btree" ("ean");



CREATE UNIQUE INDEX "idx_mv_bauhaus_blacklist_eans_ean" ON "public"."mv_bauhaus_blacklist_eans" USING "btree" ("ean");



CREATE UNIQUE INDEX "idx_mv_mr_eans_ean" ON "public"."mv_mr_eans" USING "btree" ("ean");



CREATE UNIQUE INDEX "idx_mv_scraping_activity_day" ON "public"."mv_scraping_activity_14d" USING "btree" ("day");



CREATE INDEX "idx_ph_ean" ON "public"."price_history" USING "btree" ("ean");



CREATE INDEX "idx_ph_product_id" ON "public"."price_history" USING "btree" ("product_id");



CREATE INDEX "idx_ph_recorded_at" ON "public"."price_history" USING "btree" ("recorded_at" DESC);



CREATE INDEX "idx_ph_source" ON "public"."price_history" USING "btree" ("source");



CREATE INDEX "idx_price_history_price_product_id" ON "public"."price_history" USING "btree" ("price", "product_id");



CREATE INDEX "idx_price_snapshots_product" ON "public"."price_snapshots" USING "btree" ("product_id");



CREATE INDEX "idx_price_snapshots_product_id" ON "public"."price_snapshots" USING "btree" ("product_id");



CREATE INDEX "idx_price_snapshots_product_scraped" ON "public"."price_snapshots" USING "btree" ("product_id", "scraped_at" DESC);



CREATE INDEX "idx_price_snapshots_scraped" ON "public"."price_snapshots" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_price_snapshots_scraped_at" ON "public"."price_snapshots" USING "btree" ("scraped_at");



CREATE UNIQUE INDEX "idx_products_alternate_source_id_unique" ON "public"."products" USING "btree" ("source", "alternate_id") WHERE (("source" = 'alternate'::"text") AND ("alternate_id" IS NOT NULL));



CREATE UNIQUE INDEX "idx_products_amazon_unique" ON "public"."products" USING "btree" ("amazon_asin") WHERE ("amazon_asin" IS NOT NULL);



CREATE INDEX "idx_products_bauhaus_blacklist_ean" ON "public"."products" USING "btree" ("ean") WHERE (("source" = 'bauhaus'::"text") AND ("mr_compatible" = false) AND ("ean" IS NOT NULL) AND ("ean" <> ''::"text"));



CREATE INDEX "idx_products_bauhaus_id" ON "public"."products" USING "btree" ("bauhaus_id") WHERE ("bauhaus_id" IS NOT NULL);



CREATE UNIQUE INDEX "idx_products_bauhaus_id_unique" ON "public"."products" USING "btree" ("bauhaus_id") WHERE ("bauhaus_id" IS NOT NULL);



CREATE INDEX "idx_products_blitzangebot_active" ON "public"."products" USING "btree" ("deal_end_timestamp") WHERE ("is_blitzangebot" = true);



CREATE INDEX "idx_products_brand_flagged" ON "public"."products" USING "btree" ("is_brand_flagged");



CREATE INDEX "idx_products_category" ON "public"."products" USING "btree" ("category");



CREATE INDEX "idx_products_category_path" ON "public"."products" USING "gin" ("category_path");



CREATE UNIQUE INDEX "idx_products_contorion_source_id_unique" ON "public"."products" USING "btree" ("source", "contorion_id") WHERE (("source" = 'contorion'::"text") AND ("contorion_id" IS NOT NULL));



CREATE INDEX "idx_products_country" ON "public"."products" USING "btree" ("country_code");



CREATE INDEX "idx_products_created_at" ON "public"."products" USING "btree" ("created_at");



CREATE INDEX "idx_products_datasheets_r2" ON "public"."products" USING "gin" ("datasheets_r2");



CREATE INDEX "idx_products_deal_end" ON "public"."products" USING "btree" ("deal_end_timestamp") WHERE (("is_blitzangebot" = true) AND ("deal_end_timestamp" IS NOT NULL));



CREATE INDEX "idx_products_deals" ON "public"."products" USING "btree" ("ean", "source", "price", "in_stock") WHERE (("ean" IS NOT NULL) AND ("price" > (0)::numeric) AND ("in_stock" = true));



CREATE INDEX "idx_products_deals_fast" ON "public"."products" USING "btree" ("ean", "price", "source", "in_stock") WHERE (("price" > (0)::numeric) AND ("in_stock" = true) AND ("ean" IS NOT NULL));



CREATE INDEX "idx_products_ean_country" ON "public"."products" USING "btree" ("ean", "country_code") WHERE ("ean" IS NOT NULL);



CREATE UNIQUE INDEX "idx_products_ebay_unique" ON "public"."products" USING "btree" ("ebay_item_id") WHERE ("ebay_item_id" IS NOT NULL);



CREATE INDEX "idx_products_geizhals_id" ON "public"."products" USING "btree" ("geizhals_id");



CREATE UNIQUE INDEX "idx_products_geizhals_id_unique" ON "public"."products" USING "btree" ("geizhals_id") WHERE ("geizhals_id" IS NOT NULL);



CREATE INDEX "idx_products_gotools_id" ON "public"."products" USING "btree" ("gotools_id");



CREATE UNIQUE INDEX "idx_products_gotools_id_unique" ON "public"."products" USING "btree" ("gotools_id") WHERE ("gotools_id" IS NOT NULL);



CREATE INDEX "idx_products_is_blitzangebot" ON "public"."products" USING "btree" ("is_blitzangebot") WHERE ("is_blitzangebot" = true);



CREATE INDEX "idx_products_is_refurbished" ON "public"."products" USING "btree" ("is_refurbished") WHERE ("is_refurbished" = true);



CREATE INDEX "idx_products_is_sale" ON "public"."products" USING "btree" ("is_sale") WHERE ("is_sale" = true);



CREATE INDEX "idx_products_lefeld_id" ON "public"."products" USING "btree" ("lefeld_id") WHERE ("lefeld_id" IS NOT NULL);



CREATE INDEX "idx_products_manomano_id" ON "public"."products" USING "btree" ("manomano_id");



CREATE INDEX "idx_products_mr_compatible" ON "public"."products" USING "btree" ("mr_compatible") WHERE ("source" = 'bauhaus'::"text");



CREATE INDEX "idx_products_mr_ean" ON "public"."products" USING "btree" ("ean") WHERE (("mr_compatible" IS TRUE) AND ("ean" IS NOT NULL) AND ("ean" <> ''::"text"));



CREATE INDEX "idx_products_name_fr" ON "public"."products" USING "btree" ("name_fr");



CREATE INDEX "idx_products_name_fr_null" ON "public"."products" USING "btree" ("name_fr") WHERE ("name_fr" IS NULL);



CREATE UNIQUE INDEX "idx_products_product_url" ON "public"."products" USING "btree" ("product_url");



CREATE INDEX "idx_products_source" ON "public"."products" USING "btree" ("source");



CREATE INDEX "idx_products_source_created_desc" ON "public"."products" USING "btree" ("source", "created_at" DESC) WHERE ("created_at" IS NOT NULL);



CREATE INDEX "idx_products_toolineo_id" ON "public"."products" USING "btree" ("id") WHERE ("source" = 'toolineo'::"text");



CREATE INDEX "idx_products_topdeal_cat" ON "public"."products" USING "btree" ("is_top_deal", "category") WHERE ("is_top_deal" = true);



CREATE INDEX "idx_products_topdeal_ean" ON "public"."products" USING "btree" ("ean") WHERE (("is_top_deal" = true) AND ("ean" IS NOT NULL) AND ("ean" <> ''::"text"));



CREATE INDEX "idx_products_translated" ON "public"."products" USING "btree" ("translated_at");



CREATE INDEX "idx_products_untranslated_price" ON "public"."products" USING "btree" ("price", "id") WHERE ("translated_at" IS NULL);



CREATE INDEX "idx_products_variant_group" ON "public"."products" USING "btree" ("variant_group_id") WHERE ("variant_group_id" IS NOT NULL);



CREATE INDEX "idx_products_variants" ON "public"."products" USING "gin" ("variants") WHERE ("variants" IS NOT NULL);



CREATE INDEX "idx_products_voelkner_id" ON "public"."products" USING "btree" ("voelkner_id");



CREATE UNIQUE INDEX "idx_products_voelkner_id_unique" ON "public"."products" USING "btree" ("voelkner_id") WHERE ("voelkner_id" IS NOT NULL);



CREATE INDEX "idx_ptt_id" ON "public"."products_to_translate" USING "btree" ("id");



CREATE INDEX "idx_queue_status" ON "public"."scrape_queue" USING "btree" ("status", "retries");



CREATE INDEX "idx_refurbished_brand" ON "public"."refurbished_products" USING "btree" ("brand");



CREATE INDEX "idx_refurbished_category" ON "public"."refurbished_products" USING "btree" ("category");



CREATE INDEX "idx_refurbished_grade" ON "public"."refurbished_products" USING "btree" ("grade");



CREATE INDEX "idx_refurbished_in_stock" ON "public"."refurbished_products" USING "btree" ("in_stock");



CREATE INDEX "idx_refurbished_medusa_id" ON "public"."refurbished_products" USING "btree" ("medusa_id");



CREATE INDEX "idx_refurbished_price" ON "public"."refurbished_products" USING "btree" ("price");



CREATE INDEX "idx_refurbished_source" ON "public"."refurbished_products" USING "btree" ("source");



CREATE INDEX "idx_scraping_logs_finished_at" ON "public"."scraping_logs" USING "btree" ("finished_at" DESC NULLS LAST);



CREATE INDEX "idx_scraping_logs_metadata" ON "public"."scraping_logs" USING "gin" ("metadata");



CREATE INDEX "idx_scraping_logs_source" ON "public"."scraping_logs" USING "btree" ("source");



CREATE INDEX "idx_scraping_logs_source_finished" ON "public"."scraping_logs" USING "btree" ("source", "finished_at" DESC NULLS LAST);



CREATE UNIQUE INDEX "idx_script_name_unique" ON "public"."script_migrations" USING "btree" ("script_name");



CREATE INDEX "idx_v_active_blitzangebote_hours" ON "public"."v_active_blitzangebote" USING "btree" ("hours_remaining");



CREATE UNIQUE INDEX "idx_v_active_blitzangebote_id" ON "public"."v_active_blitzangebote" USING "btree" ("id");



CREATE INDEX "idx_v_active_blitzangebote_price" ON "public"."v_active_blitzangebote" USING "btree" ("price_current") WHERE ("price_current" IS NOT NULL);



CREATE INDEX "mv_best_deals_by_ean_discount_idx" ON "public"."mv_best_deals_by_ean" USING "btree" ("discount_pct" DESC);



CREATE UNIQUE INDEX "mv_best_deals_by_ean_ean_idx" ON "public"."mv_best_deals_by_ean" USING "btree" ("ean");



CREATE INDEX "mv_products_unit_price_ean_idx" ON "public"."mv_products_unit_price" USING "btree" ("ean");



CREATE UNIQUE INDEX "mv_products_unit_price_id_idx" ON "public"."mv_products_unit_price" USING "btree" ("id");



CREATE INDEX "mv_products_unit_price_source_idx" ON "public"."mv_products_unit_price" USING "btree" ("source");



CREATE INDEX "price_snapshots_product_scraped_idx" ON "public"."price_snapshots" USING "btree" ("product_id", "scraped_at" DESC);



CREATE INDEX "products_ean_id_idx" ON "public"."products" USING "btree" ("ean", "id") WHERE ("ean" IS NOT NULL);



CREATE UNIQUE INDEX "products_ean_source_unique" ON "public"."products" USING "btree" ("ean", "source") WHERE (("ean" IS NOT NULL) AND ("ean" <> ''::"text"));



CREATE INDEX "products_embedding_idx" ON "public"."products" USING "ivfflat" ("embedding" "public"."vector_cosine_ops");



CREATE INDEX "products_id_ean_idx" ON "public"."products" USING "btree" ("id", "ean");



CREATE INDEX "products_mpn_idx" ON "public"."products" USING "btree" ("mpn") WHERE (("mpn" IS NOT NULL) AND ("mpn" <> ''::"text"));



CREATE UNIQUE INDEX "products_source_alternate_id_uq" ON "public"."products" USING "btree" ("source", "alternate_id") WHERE (("source" = 'alternate'::"text") AND ("alternate_id" IS NOT NULL));



CREATE UNIQUE INDEX "products_source_product_url_uidx" ON "public"."products" USING "btree" ("source", "product_url");



CREATE INDEX "technikdirekt_products_all_variants_gin_idx" ON "public"."technikdirekt_products" USING "gin" ("all_variants_json");



CREATE INDEX "technikdirekt_products_ean_idx" ON "public"."technikdirekt_products" USING "btree" ("ean");



CREATE INDEX "technikdirekt_products_image_urls_gin_idx" ON "public"."technikdirekt_products" USING "gin" ("image_urls_json");



CREATE INDEX "technikdirekt_products_is_variant_idx" ON "public"."technikdirekt_products" USING "btree" ("is_variant");



CREATE INDEX "technikdirekt_products_parent_url_idx" ON "public"."technikdirekt_products" USING "btree" ("parent_url");



CREATE INDEX "technikdirekt_products_price_num_idx" ON "public"."technikdirekt_products" USING "btree" ("price_num");



CREATE INDEX "technikdirekt_products_price_original_num_idx" ON "public"."technikdirekt_products" USING "btree" ("price_original_num");



CREATE UNIQUE INDEX "technikdirekt_products_product_url_uidx" ON "public"."technikdirekt_products" USING "btree" ("product_url");



CREATE INDEX "technikdirekt_products_scraped_at_idx" ON "public"."technikdirekt_products" USING "btree" ("scraped_at");



CREATE INDEX "technikdirekt_products_sku_idx" ON "public"."technikdirekt_products" USING "btree" ("sku");



CREATE INDEX "technikdirekt_products_specifications_gin_idx" ON "public"."technikdirekt_products" USING "gin" ("specifications_json");



CREATE INDEX "v_deals_blacklist_filtered_discount_idx" ON "public"."v_deals_blacklist_filtered" USING "btree" ("discount_pct" DESC);



CREATE UNIQUE INDEX "v_deals_blacklist_filtered_ean_idx" ON "public"."v_deals_blacklist_filtered" USING "btree" ("ean");



CREATE OR REPLACE TRIGGER "bauportal_products_sync_to_products_trg" AFTER INSERT OR UPDATE ON "public"."bauportal_products" FOR EACH ROW EXECUTE FUNCTION "public"."sync_any_scraper_product_to_products"();



CREATE OR REPLACE TRIGGER "contorion_products_sync_to_products_trg" AFTER INSERT OR UPDATE ON "public"."contorion_products" FOR EACH ROW EXECUTE FUNCTION "public"."sync_any_scraper_product_to_products"();



CREATE OR REPLACE TRIGGER "resolve_ean_from_mpn_trigger" BEFORE INSERT OR UPDATE ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."resolve_ean_from_mpn"();



CREATE OR REPLACE TRIGGER "technikdirekt_products_sync_to_products_trg" AFTER INSERT OR UPDATE ON "public"."technikdirekt_products" FOR EACH ROW EXECUTE FUNCTION "public"."sync_any_scraper_product_to_products"();



CREATE OR REPLACE TRIGGER "trg_fill_ean_from_payload" BEFORE INSERT OR UPDATE OF "ean", "specs", "description" ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."fill_ean_from_payload"();



CREATE OR REPLACE TRIGGER "trg_price_history" AFTER INSERT OR UPDATE ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."record_price_change"();



CREATE OR REPLACE TRIGGER "trg_products_updated" BEFORE UPDATE ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "trg_sync_products_to_translate" AFTER INSERT OR UPDATE ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."sync_products_to_translate"();



CREATE OR REPLACE TRIGGER "trg_technikdirekt_products_updated_at" BEFORE UPDATE ON "public"."technikdirekt_products" FOR EACH ROW EXECUTE FUNCTION "public"."set_technikdirekt_updated_at"();



CREATE OR REPLACE TRIGGER "trg_update_is_top_deal" AFTER INSERT ON "public"."price_history" FOR EACH ROW EXECUTE FUNCTION "public"."update_is_top_deal"();



CREATE OR REPLACE TRIGGER "trg_voelkner_mr_compatible" BEFORE INSERT OR UPDATE ON "public"."products" FOR EACH ROW WHEN (("new"."source" = 'voelkner'::"text")) EXECUTE FUNCTION "public"."auto_mr_compatible_voelkner"();



CREATE OR REPLACE TRIGGER "trg_werkzeug_snapshot" AFTER INSERT OR UPDATE ON "public"."products" FOR EACH ROW WHEN ((("new"."source" = 'werkzeug_guenstig'::"text") AND ("new"."price" IS NOT NULL))) EXECUTE FUNCTION "public"."auto_price_snapshot"();



ALTER TABLE ONLY "public"."tax_rate_rule"
    ADD CONSTRAINT "FK_tax_rate_rule_tax_rate_id" FOREIGN KEY ("tax_rate_id") REFERENCES "public"."tax_rate"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tax_rate"
    ADD CONSTRAINT "FK_tax_rate_tax_region_id" FOREIGN KEY ("tax_region_id") REFERENCES "public"."tax_region"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tax_region"
    ADD CONSTRAINT "FK_tax_region_parent_id" FOREIGN KEY ("parent_id") REFERENCES "public"."tax_region"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tax_region"
    ADD CONSTRAINT "FK_tax_region_provider_id" FOREIGN KEY ("provider_id") REFERENCES "public"."tax_provider"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."application_method_buy_rules"
    ADD CONSTRAINT "application_method_buy_rules_application_method_id_foreign" FOREIGN KEY ("application_method_id") REFERENCES "public"."promotion_application_method"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."application_method_buy_rules"
    ADD CONSTRAINT "application_method_buy_rules_promotion_rule_id_foreign" FOREIGN KEY ("promotion_rule_id") REFERENCES "public"."promotion_rule"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."application_method_target_rules"
    ADD CONSTRAINT "application_method_target_rules_application_method_id_foreign" FOREIGN KEY ("application_method_id") REFERENCES "public"."promotion_application_method"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."application_method_target_rules"
    ADD CONSTRAINT "application_method_target_rules_promotion_rule_id_foreign" FOREIGN KEY ("promotion_rule_id") REFERENCES "public"."promotion_rule"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."capture"
    ADD CONSTRAINT "capture_payment_id_foreign" FOREIGN KEY ("payment_id") REFERENCES "public"."payment"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cart"
    ADD CONSTRAINT "cart_billing_address_id_foreign" FOREIGN KEY ("billing_address_id") REFERENCES "public"."cart_address"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."cart_line_item_adjustment"
    ADD CONSTRAINT "cart_line_item_adjustment_item_id_foreign" FOREIGN KEY ("item_id") REFERENCES "public"."cart_line_item"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cart_line_item"
    ADD CONSTRAINT "cart_line_item_cart_id_foreign" FOREIGN KEY ("cart_id") REFERENCES "public"."cart"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cart_line_item_tax_line"
    ADD CONSTRAINT "cart_line_item_tax_line_item_id_foreign" FOREIGN KEY ("item_id") REFERENCES "public"."cart_line_item"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cart"
    ADD CONSTRAINT "cart_shipping_address_id_foreign" FOREIGN KEY ("shipping_address_id") REFERENCES "public"."cart_address"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."cart_shipping_method_adjustment"
    ADD CONSTRAINT "cart_shipping_method_adjustment_shipping_method_id_foreign" FOREIGN KEY ("shipping_method_id") REFERENCES "public"."cart_shipping_method"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cart_shipping_method"
    ADD CONSTRAINT "cart_shipping_method_cart_id_foreign" FOREIGN KEY ("cart_id") REFERENCES "public"."cart"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cart_shipping_method_tax_line"
    ADD CONSTRAINT "cart_shipping_method_tax_line_shipping_method_id_foreign" FOREIGN KEY ("shipping_method_id") REFERENCES "public"."cart_shipping_method"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."credit_line"
    ADD CONSTRAINT "credit_line_cart_id_foreign" FOREIGN KEY ("cart_id") REFERENCES "public"."cart"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."customer_address"
    ADD CONSTRAINT "customer_address_customer_id_foreign" FOREIGN KEY ("customer_id") REFERENCES "public"."customer"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."customer_group_customer"
    ADD CONSTRAINT "customer_group_customer_customer_group_id_foreign" FOREIGN KEY ("customer_group_id") REFERENCES "public"."customer_group"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."customer_group_customer"
    ADD CONSTRAINT "customer_group_customer_customer_id_foreign" FOREIGN KEY ("customer_id") REFERENCES "public"."customer"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fr_price_comparisons"
    ADD CONSTRAINT "fr_price_comparisons_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fulfillment"
    ADD CONSTRAINT "fulfillment_delivery_address_id_foreign" FOREIGN KEY ("delivery_address_id") REFERENCES "public"."fulfillment_address"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."fulfillment_item"
    ADD CONSTRAINT "fulfillment_item_fulfillment_id_foreign" FOREIGN KEY ("fulfillment_id") REFERENCES "public"."fulfillment"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fulfillment_label"
    ADD CONSTRAINT "fulfillment_label_fulfillment_id_foreign" FOREIGN KEY ("fulfillment_id") REFERENCES "public"."fulfillment"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fulfillment"
    ADD CONSTRAINT "fulfillment_provider_id_foreign" FOREIGN KEY ("provider_id") REFERENCES "public"."fulfillment_provider"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."fulfillment"
    ADD CONSTRAINT "fulfillment_shipping_option_id_foreign" FOREIGN KEY ("shipping_option_id") REFERENCES "public"."shipping_option"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."geo_zone"
    ADD CONSTRAINT "geo_zone_service_zone_id_foreign" FOREIGN KEY ("service_zone_id") REFERENCES "public"."service_zone"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."image"
    ADD CONSTRAINT "image_product_id_foreign" FOREIGN KEY ("product_id") REFERENCES "public"."product"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_level"
    ADD CONSTRAINT "inventory_level_inventory_item_id_foreign" FOREIGN KEY ("inventory_item_id") REFERENCES "public"."inventory_item"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notification"
    ADD CONSTRAINT "notification_provider_id_foreign" FOREIGN KEY ("provider_id") REFERENCES "public"."notification_provider"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order"
    ADD CONSTRAINT "order_billing_address_id_foreign" FOREIGN KEY ("billing_address_id") REFERENCES "public"."order_address"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_change_action"
    ADD CONSTRAINT "order_change_action_order_change_id_foreign" FOREIGN KEY ("order_change_id") REFERENCES "public"."order_change"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_change"
    ADD CONSTRAINT "order_change_order_id_foreign" FOREIGN KEY ("order_id") REFERENCES "public"."order"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_credit_line"
    ADD CONSTRAINT "order_credit_line_order_id_foreign" FOREIGN KEY ("order_id") REFERENCES "public"."order"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_item"
    ADD CONSTRAINT "order_item_item_id_foreign" FOREIGN KEY ("item_id") REFERENCES "public"."order_line_item"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_item"
    ADD CONSTRAINT "order_item_order_id_foreign" FOREIGN KEY ("order_id") REFERENCES "public"."order"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_line_item_adjustment"
    ADD CONSTRAINT "order_line_item_adjustment_item_id_foreign" FOREIGN KEY ("item_id") REFERENCES "public"."order_line_item"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_line_item_tax_line"
    ADD CONSTRAINT "order_line_item_tax_line_item_id_foreign" FOREIGN KEY ("item_id") REFERENCES "public"."order_line_item"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_line_item"
    ADD CONSTRAINT "order_line_item_totals_id_foreign" FOREIGN KEY ("totals_id") REFERENCES "public"."order_item"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order"
    ADD CONSTRAINT "order_shipping_address_id_foreign" FOREIGN KEY ("shipping_address_id") REFERENCES "public"."order_address"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_shipping_method_adjustment"
    ADD CONSTRAINT "order_shipping_method_adjustment_shipping_method_id_foreign" FOREIGN KEY ("shipping_method_id") REFERENCES "public"."order_shipping_method"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_shipping_method_tax_line"
    ADD CONSTRAINT "order_shipping_method_tax_line_shipping_method_id_foreign" FOREIGN KEY ("shipping_method_id") REFERENCES "public"."order_shipping_method"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_shipping"
    ADD CONSTRAINT "order_shipping_order_id_foreign" FOREIGN KEY ("order_id") REFERENCES "public"."order"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_summary"
    ADD CONSTRAINT "order_summary_order_id_foreign" FOREIGN KEY ("order_id") REFERENCES "public"."order"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_transaction"
    ADD CONSTRAINT "order_transaction_order_id_foreign" FOREIGN KEY ("order_id") REFERENCES "public"."order"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_collection_payment_providers"
    ADD CONSTRAINT "payment_collection_payment_providers_payment_col_aa276_foreign" FOREIGN KEY ("payment_collection_id") REFERENCES "public"."payment_collection"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_collection_payment_providers"
    ADD CONSTRAINT "payment_collection_payment_providers_payment_pro_2d555_foreign" FOREIGN KEY ("payment_provider_id") REFERENCES "public"."payment_provider"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment"
    ADD CONSTRAINT "payment_payment_collection_id_foreign" FOREIGN KEY ("payment_collection_id") REFERENCES "public"."payment_collection"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_session"
    ADD CONSTRAINT "payment_session_payment_collection_id_foreign" FOREIGN KEY ("payment_collection_id") REFERENCES "public"."payment_collection"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_list_rule"
    ADD CONSTRAINT "price_list_rule_price_list_id_foreign" FOREIGN KEY ("price_list_id") REFERENCES "public"."price_list"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price"
    ADD CONSTRAINT "price_price_list_id_foreign" FOREIGN KEY ("price_list_id") REFERENCES "public"."price_list"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price"
    ADD CONSTRAINT "price_price_set_id_foreign" FOREIGN KEY ("price_set_id") REFERENCES "public"."price_set"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_rule"
    ADD CONSTRAINT "price_rule_price_id_foreign" FOREIGN KEY ("price_id") REFERENCES "public"."price"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_snapshots"
    ADD CONSTRAINT "price_snapshots_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_category"
    ADD CONSTRAINT "product_category_parent_category_id_foreign" FOREIGN KEY ("parent_category_id") REFERENCES "public"."product_category"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_category_product"
    ADD CONSTRAINT "product_category_product_product_category_id_foreign" FOREIGN KEY ("product_category_id") REFERENCES "public"."product_category"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_category_product"
    ADD CONSTRAINT "product_category_product_product_id_foreign" FOREIGN KEY ("product_id") REFERENCES "public"."product"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product"
    ADD CONSTRAINT "product_collection_id_foreign" FOREIGN KEY ("collection_id") REFERENCES "public"."product_collection"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."product_option"
    ADD CONSTRAINT "product_option_product_id_foreign" FOREIGN KEY ("product_id") REFERENCES "public"."product"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_option_value"
    ADD CONSTRAINT "product_option_value_option_id_foreign" FOREIGN KEY ("option_id") REFERENCES "public"."product_option"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_tags"
    ADD CONSTRAINT "product_tags_product_id_foreign" FOREIGN KEY ("product_id") REFERENCES "public"."product"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_tags"
    ADD CONSTRAINT "product_tags_product_tag_id_foreign" FOREIGN KEY ("product_tag_id") REFERENCES "public"."product_tag"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product"
    ADD CONSTRAINT "product_type_id_foreign" FOREIGN KEY ("type_id") REFERENCES "public"."product_type"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."product_variant_option"
    ADD CONSTRAINT "product_variant_option_option_value_id_foreign" FOREIGN KEY ("option_value_id") REFERENCES "public"."product_option_value"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_variant_option"
    ADD CONSTRAINT "product_variant_option_variant_id_foreign" FOREIGN KEY ("variant_id") REFERENCES "public"."product_variant"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_variant"
    ADD CONSTRAINT "product_variant_product_id_foreign" FOREIGN KEY ("product_id") REFERENCES "public"."product"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_variant_product_image"
    ADD CONSTRAINT "product_variant_product_image_image_id_foreign" FOREIGN KEY ("image_id") REFERENCES "public"."image"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promotion_application_method"
    ADD CONSTRAINT "promotion_application_method_promotion_id_foreign" FOREIGN KEY ("promotion_id") REFERENCES "public"."promotion"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promotion_campaign_budget"
    ADD CONSTRAINT "promotion_campaign_budget_campaign_id_foreign" FOREIGN KEY ("campaign_id") REFERENCES "public"."promotion_campaign"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promotion_campaign_budget_usage"
    ADD CONSTRAINT "promotion_campaign_budget_usage_budget_id_foreign" FOREIGN KEY ("budget_id") REFERENCES "public"."promotion_campaign_budget"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promotion"
    ADD CONSTRAINT "promotion_campaign_id_foreign" FOREIGN KEY ("campaign_id") REFERENCES "public"."promotion_campaign"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."promotion_promotion_rule"
    ADD CONSTRAINT "promotion_promotion_rule_promotion_id_foreign" FOREIGN KEY ("promotion_id") REFERENCES "public"."promotion"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promotion_promotion_rule"
    ADD CONSTRAINT "promotion_promotion_rule_promotion_rule_id_foreign" FOREIGN KEY ("promotion_rule_id") REFERENCES "public"."promotion_rule"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promotion_rule_value"
    ADD CONSTRAINT "promotion_rule_value_promotion_rule_id_foreign" FOREIGN KEY ("promotion_rule_id") REFERENCES "public"."promotion_rule"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."provider_identity"
    ADD CONSTRAINT "provider_identity_auth_identity_id_foreign" FOREIGN KEY ("auth_identity_id") REFERENCES "public"."auth_identity"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."refund"
    ADD CONSTRAINT "refund_payment_id_foreign" FOREIGN KEY ("payment_id") REFERENCES "public"."payment"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."region_country"
    ADD CONSTRAINT "region_country_region_id_foreign" FOREIGN KEY ("region_id") REFERENCES "public"."region"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."reservation_item"
    ADD CONSTRAINT "reservation_item_inventory_item_id_foreign" FOREIGN KEY ("inventory_item_id") REFERENCES "public"."inventory_item"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."return_reason"
    ADD CONSTRAINT "return_reason_parent_return_reason_id_foreign" FOREIGN KEY ("parent_return_reason_id") REFERENCES "public"."return_reason"("id");



ALTER TABLE ONLY "public"."service_zone"
    ADD CONSTRAINT "service_zone_fulfillment_set_id_foreign" FOREIGN KEY ("fulfillment_set_id") REFERENCES "public"."fulfillment_set"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shipping_option"
    ADD CONSTRAINT "shipping_option_provider_id_foreign" FOREIGN KEY ("provider_id") REFERENCES "public"."fulfillment_provider"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."shipping_option_rule"
    ADD CONSTRAINT "shipping_option_rule_shipping_option_id_foreign" FOREIGN KEY ("shipping_option_id") REFERENCES "public"."shipping_option"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shipping_option"
    ADD CONSTRAINT "shipping_option_service_zone_id_foreign" FOREIGN KEY ("service_zone_id") REFERENCES "public"."service_zone"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shipping_option"
    ADD CONSTRAINT "shipping_option_shipping_option_type_id_foreign" FOREIGN KEY ("shipping_option_type_id") REFERENCES "public"."shipping_option_type"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."shipping_option"
    ADD CONSTRAINT "shipping_option_shipping_profile_id_foreign" FOREIGN KEY ("shipping_profile_id") REFERENCES "public"."shipping_profile"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."stock_location"
    ADD CONSTRAINT "stock_location_address_id_foreign" FOREIGN KEY ("address_id") REFERENCES "public"."stock_location_address"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."store_currency"
    ADD CONSTRAINT "store_currency_store_id_foreign" FOREIGN KEY ("store_id") REFERENCES "public"."store"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."store_locale"
    ADD CONSTRAINT "store_locale_store_id_foreign" FOREIGN KEY ("store_id") REFERENCES "public"."store"("id") ON UPDATE CASCADE ON DELETE CASCADE;



CREATE POLICY "Lecture publique brand_blacklist" ON "public"."brand_blacklist" FOR SELECT USING (true);



CREATE POLICY "Lecture publique price_snapshots" ON "public"."price_snapshots" FOR SELECT USING (true);



CREATE POLICY "Lecture publique products" ON "public"."products" FOR SELECT USING (true);



CREATE POLICY "Lecture publique scraping_logs" ON "public"."scraping_logs" FOR SELECT USING (true);



CREATE POLICY "Service role full access brand_blacklist" ON "public"."brand_blacklist" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access price_snapshots" ON "public"."price_snapshots" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access products" ON "public"."products" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access scraping_logs" ON "public"."scraping_logs" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."multi_source_eans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."secondbuy_stock_history" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service_role_all" ON "public"."products_to_translate" TO "service_role" USING (true);



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."add_deals_ean_blacklist"("p_ean" "text", "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."add_deals_ean_blacklist"("p_ean" "text", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_deals_ean_blacklist"("p_ean" "text", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."add_deals_ean_blacklist_bulk"("p_eans" "text"[], "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."add_deals_ean_blacklist_bulk"("p_eans" "text"[], "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_deals_ean_blacklist_bulk"("p_eans" "text"[], "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."add_deals_ean_blacklist_from_search"("p_search" "text", "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[], "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."add_deals_ean_blacklist_from_search"("p_search" "text", "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[], "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_deals_ean_blacklist_from_search"("p_search" "text", "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[], "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."attach_scraper_sync_trigger"("p_table" "regclass") TO "anon";
GRANT ALL ON FUNCTION "public"."attach_scraper_sync_trigger"("p_table" "regclass") TO "authenticated";
GRANT ALL ON FUNCTION "public"."attach_scraper_sync_trigger"("p_table" "regclass") TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_mr_compatible_voelkner"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_mr_compatible_voelkner"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_mr_compatible_voelkner"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_price_snapshot"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_price_snapshot"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_price_snapshot"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bootstrap_all_scraper_triggers"() TO "anon";
GRANT ALL ON FUNCTION "public"."bootstrap_all_scraper_triggers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bootstrap_all_scraper_triggers"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clear_deals_ean_blacklist"() TO "anon";
GRANT ALL ON FUNCTION "public"."clear_deals_ean_blacklist"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_deals_ean_blacklist"() TO "service_role";



GRANT ALL ON FUNCTION "public"."extract_max_dim_cm"("specs" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."extract_max_dim_cm"("specs" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."extract_max_dim_cm"("specs" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."extract_pack_quantity"("name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."extract_pack_quantity"("name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."extract_pack_quantity"("name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."extract_weight_kg"("specs" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."extract_weight_kg"("specs" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."extract_weight_kg"("specs" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_ean_from_payload"() TO "anon";
GRANT ALL ON FUNCTION "public"."fill_ean_from_payload"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_ean_from_payload"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fix_pack_quantity_by_consensus"() TO "anon";
GRANT ALL ON FUNCTION "public"."fix_pack_quantity_by_consensus"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fix_pack_quantity_by_consensus"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_active_blitzangebote"("limit_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_active_blitzangebote"("limit_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_active_blitzangebote"("limit_count" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_best_deals"("min_savings_pct" numeric, "max_results" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_best_deals"("min_savings_pct" numeric, "max_results" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_best_deals"("min_savings_pct" numeric, "max_results" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_dashboard_stats"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_dashboard_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_dashboard_stats"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_deals_count_mr"("p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_deals_count_mr"("p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_deals_count_mr"("p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_deals_count_mr_search"("p_search" "text", "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_deals_count_mr_search"("p_search" "text", "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_deals_count_mr_search"("p_search" "text", "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_deals_page_mr"("p_page" integer, "p_page_size" integer, "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_sort_by" "text", "p_sort_dir" "text", "p_scrapers" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_deals_page_mr"("p_page" integer, "p_page_size" integer, "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_sort_by" "text", "p_sort_dir" "text", "p_scrapers" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_deals_page_mr"("p_page" integer, "p_page_size" integer, "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_sort_by" "text", "p_sort_dir" "text", "p_scrapers" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_deals_page_mr_search"("p_search" "text", "p_page" integer, "p_page_size" integer, "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_sort_by" "text", "p_sort_dir" "text", "p_scrapers" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_deals_page_mr_search"("p_search" "text", "p_page" integer, "p_page_size" integer, "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_sort_by" "text", "p_sort_dir" "text", "p_scrapers" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_deals_page_mr_search"("p_search" "text", "p_page" integer, "p_page_size" integer, "p_min_savings" numeric, "p_min_sources" integer, "p_price_min" numeric, "p_price_max" numeric, "p_sort_by" "text", "p_sort_dir" "text", "p_scrapers" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_duplicate_eans"("min_sources" integer, "min_savings_pct" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."get_duplicate_eans"("min_sources" integer, "min_savings_pct" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_duplicate_eans"("min_sources" integer, "min_savings_pct" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_latest_price_drops"("source_filter" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_latest_price_drops"("source_filter" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_latest_price_drops"("source_filter" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_product_counts_by_source"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_product_counts_by_source"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_product_counts_by_source"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_products_count_mr"("p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_products_count_mr"("p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_products_count_mr"("p_price_min" numeric, "p_price_max" numeric, "p_scrapers" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_products_to_translate"("p_limit" integer, "p_min_price" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."get_products_to_translate"("p_limit" integer, "p_min_price" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_products_to_translate"("p_limit" integer, "p_min_price" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_scraper_activity"("hours_window" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_scraper_activity"("hours_window" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_scraper_activity"("hours_window" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_scraper_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_scraper_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_scraper_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_scraper_statut"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_scraper_statut"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_scraper_statut"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_scraping_activity_chart"("days_back" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_scraping_activity_chart"("days_back" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_scraping_activity_chart"("days_back" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_top_deals"("min_savings_pct" numeric, "max_results" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_top_deals"("min_savings_pct" numeric, "max_results" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_top_deals"("min_savings_pct" numeric, "max_results" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."log_scraping_run"("p_source" "text", "p_run_type" "text", "p_products_found" integer, "p_duration_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."log_scraping_run"("p_source" "text", "p_run_type" "text", "p_products_found" integer, "p_duration_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_scraping_run"("p_source" "text", "p_run_type" "text", "p_products_found" integer, "p_duration_seconds" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_search_de"("p_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_search_de"("p_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_search_de"("p_text" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."record_price_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."record_price_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_price_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_active_blitzangebote"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_active_blitzangebote"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_active_blitzangebote"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_deals_cache"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_deals_cache"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_deals_cache"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_mr_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_mr_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_mr_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_mr_status"("p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_mr_status"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_mr_status"("p_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_mv_best_deals_by_ean_safe"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_mv_best_deals_by_ean_safe"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_mv_best_deals_by_ean_safe"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_mv_deals_by_ean"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_mv_deals_by_ean"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_mv_deals_by_ean"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_mv_products"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_mv_products"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_mv_products"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_mv_products_unit_price"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_mv_products_unit_price"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_mv_products_unit_price"() TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_deals_ean_blacklist"("p_ean" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_deals_ean_blacklist"("p_ean" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_deals_ean_blacklist"("p_ean" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_ean_from_mpn"() TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_ean_from_mpn"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_ean_from_mpn"() TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_ean_from_mpn_batch"() TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_ean_from_mpn_batch"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_ean_from_mpn_batch"() TO "service_role";



GRANT ALL ON FUNCTION "public"."search_products_smart"("search_term" "text", "in_stock_only" boolean, "limit_results" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."search_products_smart"("search_term" "text", "in_stock_only" boolean, "limit_results" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_products_smart"("search_term" "text", "in_stock_only" boolean, "limit_results" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_technikdirekt_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_technikdirekt_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_technikdirekt_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_any_scraper_product_to_products"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_any_scraper_product_to_products"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_any_scraper_product_to_products"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_products_to_translate"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_products_to_translate"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_products_to_translate"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_scraper_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_scraper_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_scraper_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_is_top_deal"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_is_top_deal"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_is_top_deal"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";



GRANT ALL ON TABLE "public"."account_holder" TO "anon";
GRANT ALL ON TABLE "public"."account_holder" TO "authenticated";
GRANT ALL ON TABLE "public"."account_holder" TO "service_role";



GRANT ALL ON TABLE "public"."api_key" TO "anon";
GRANT ALL ON TABLE "public"."api_key" TO "authenticated";
GRANT ALL ON TABLE "public"."api_key" TO "service_role";



GRANT ALL ON TABLE "public"."application_method_buy_rules" TO "anon";
GRANT ALL ON TABLE "public"."application_method_buy_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."application_method_buy_rules" TO "service_role";



GRANT ALL ON TABLE "public"."application_method_target_rules" TO "anon";
GRANT ALL ON TABLE "public"."application_method_target_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."application_method_target_rules" TO "service_role";



GRANT ALL ON TABLE "public"."auth_identity" TO "anon";
GRANT ALL ON TABLE "public"."auth_identity" TO "authenticated";
GRANT ALL ON TABLE "public"."auth_identity" TO "service_role";



GRANT ALL ON TABLE "public"."bauportal_products" TO "anon";
GRANT ALL ON TABLE "public"."bauportal_products" TO "authenticated";
GRANT ALL ON TABLE "public"."bauportal_products" TO "service_role";



GRANT ALL ON TABLE "public"."brand_blacklist" TO "anon";
GRANT ALL ON TABLE "public"."brand_blacklist" TO "authenticated";
GRANT ALL ON TABLE "public"."brand_blacklist" TO "service_role";



GRANT ALL ON TABLE "public"."capture" TO "anon";
GRANT ALL ON TABLE "public"."capture" TO "authenticated";
GRANT ALL ON TABLE "public"."capture" TO "service_role";



GRANT ALL ON TABLE "public"."cart" TO "anon";
GRANT ALL ON TABLE "public"."cart" TO "authenticated";
GRANT ALL ON TABLE "public"."cart" TO "service_role";



GRANT ALL ON TABLE "public"."cart_address" TO "anon";
GRANT ALL ON TABLE "public"."cart_address" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_address" TO "service_role";



GRANT ALL ON TABLE "public"."cart_line_item" TO "anon";
GRANT ALL ON TABLE "public"."cart_line_item" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_line_item" TO "service_role";



GRANT ALL ON TABLE "public"."cart_line_item_adjustment" TO "anon";
GRANT ALL ON TABLE "public"."cart_line_item_adjustment" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_line_item_adjustment" TO "service_role";



GRANT ALL ON TABLE "public"."cart_line_item_tax_line" TO "anon";
GRANT ALL ON TABLE "public"."cart_line_item_tax_line" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_line_item_tax_line" TO "service_role";



GRANT ALL ON TABLE "public"."cart_payment_collection" TO "anon";
GRANT ALL ON TABLE "public"."cart_payment_collection" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_payment_collection" TO "service_role";



GRANT ALL ON TABLE "public"."cart_promotion" TO "anon";
GRANT ALL ON TABLE "public"."cart_promotion" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_promotion" TO "service_role";



GRANT ALL ON TABLE "public"."cart_shipping_method" TO "anon";
GRANT ALL ON TABLE "public"."cart_shipping_method" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_shipping_method" TO "service_role";



GRANT ALL ON TABLE "public"."cart_shipping_method_adjustment" TO "anon";
GRANT ALL ON TABLE "public"."cart_shipping_method_adjustment" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_shipping_method_adjustment" TO "service_role";



GRANT ALL ON TABLE "public"."cart_shipping_method_tax_line" TO "anon";
GRANT ALL ON TABLE "public"."cart_shipping_method_tax_line" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_shipping_method_tax_line" TO "service_role";



GRANT ALL ON TABLE "public"."contorion_products" TO "anon";
GRANT ALL ON TABLE "public"."contorion_products" TO "authenticated";
GRANT ALL ON TABLE "public"."contorion_products" TO "service_role";



GRANT ALL ON TABLE "public"."credit_line" TO "anon";
GRANT ALL ON TABLE "public"."credit_line" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_line" TO "service_role";



GRANT ALL ON TABLE "public"."currency" TO "anon";
GRANT ALL ON TABLE "public"."currency" TO "authenticated";
GRANT ALL ON TABLE "public"."currency" TO "service_role";



GRANT ALL ON TABLE "public"."customer" TO "anon";
GRANT ALL ON TABLE "public"."customer" TO "authenticated";
GRANT ALL ON TABLE "public"."customer" TO "service_role";



GRANT ALL ON TABLE "public"."customer_account_holder" TO "anon";
GRANT ALL ON TABLE "public"."customer_account_holder" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_account_holder" TO "service_role";



GRANT ALL ON TABLE "public"."customer_address" TO "anon";
GRANT ALL ON TABLE "public"."customer_address" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_address" TO "service_role";



GRANT ALL ON TABLE "public"."customer_group" TO "anon";
GRANT ALL ON TABLE "public"."customer_group" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_group" TO "service_role";



GRANT ALL ON TABLE "public"."customer_group_customer" TO "anon";
GRANT ALL ON TABLE "public"."customer_group_customer" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_group_customer" TO "service_role";



GRANT ALL ON TABLE "public"."deals_ean_blacklist" TO "anon";
GRANT ALL ON TABLE "public"."deals_ean_blacklist" TO "authenticated";
GRANT ALL ON TABLE "public"."deals_ean_blacklist" TO "service_role";



GRANT ALL ON TABLE "public"."products" TO "anon";
GRANT ALL ON TABLE "public"."products" TO "authenticated";
GRANT ALL ON TABLE "public"."products" TO "service_role";



GRANT ALL ON TABLE "public"."deals_eligible_products" TO "anon";
GRANT ALL ON TABLE "public"."deals_eligible_products" TO "authenticated";
GRANT ALL ON TABLE "public"."deals_eligible_products" TO "service_role";



GRANT ALL ON TABLE "public"."deals_eligible_werkzeug_guenstig" TO "anon";
GRANT ALL ON TABLE "public"."deals_eligible_werkzeug_guenstig" TO "authenticated";
GRANT ALL ON TABLE "public"."deals_eligible_werkzeug_guenstig" TO "service_role";



GRANT ALL ON TABLE "public"."fr_price_comparisons" TO "anon";
GRANT ALL ON TABLE "public"."fr_price_comparisons" TO "authenticated";
GRANT ALL ON TABLE "public"."fr_price_comparisons" TO "service_role";



GRANT ALL ON TABLE "public"."fulfillment" TO "anon";
GRANT ALL ON TABLE "public"."fulfillment" TO "authenticated";
GRANT ALL ON TABLE "public"."fulfillment" TO "service_role";



GRANT ALL ON TABLE "public"."fulfillment_address" TO "anon";
GRANT ALL ON TABLE "public"."fulfillment_address" TO "authenticated";
GRANT ALL ON TABLE "public"."fulfillment_address" TO "service_role";



GRANT ALL ON TABLE "public"."fulfillment_item" TO "anon";
GRANT ALL ON TABLE "public"."fulfillment_item" TO "authenticated";
GRANT ALL ON TABLE "public"."fulfillment_item" TO "service_role";



GRANT ALL ON TABLE "public"."fulfillment_label" TO "anon";
GRANT ALL ON TABLE "public"."fulfillment_label" TO "authenticated";
GRANT ALL ON TABLE "public"."fulfillment_label" TO "service_role";



GRANT ALL ON TABLE "public"."fulfillment_provider" TO "anon";
GRANT ALL ON TABLE "public"."fulfillment_provider" TO "authenticated";
GRANT ALL ON TABLE "public"."fulfillment_provider" TO "service_role";



GRANT ALL ON TABLE "public"."fulfillment_set" TO "anon";
GRANT ALL ON TABLE "public"."fulfillment_set" TO "authenticated";
GRANT ALL ON TABLE "public"."fulfillment_set" TO "service_role";



GRANT ALL ON TABLE "public"."geo_zone" TO "anon";
GRANT ALL ON TABLE "public"."geo_zone" TO "authenticated";
GRANT ALL ON TABLE "public"."geo_zone" TO "service_role";



GRANT ALL ON TABLE "public"."hardware_online_products" TO "anon";
GRANT ALL ON TABLE "public"."hardware_online_products" TO "authenticated";
GRANT ALL ON TABLE "public"."hardware_online_products" TO "service_role";



GRANT ALL ON TABLE "public"."image" TO "anon";
GRANT ALL ON TABLE "public"."image" TO "authenticated";
GRANT ALL ON TABLE "public"."image" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_item" TO "anon";
GRANT ALL ON TABLE "public"."inventory_item" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_item" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_level" TO "anon";
GRANT ALL ON TABLE "public"."inventory_level" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_level" TO "service_role";



GRANT ALL ON TABLE "public"."invite" TO "anon";
GRANT ALL ON TABLE "public"."invite" TO "authenticated";
GRANT ALL ON TABLE "public"."invite" TO "service_role";



GRANT ALL ON TABLE "public"."invite_rbac_role" TO "anon";
GRANT ALL ON TABLE "public"."invite_rbac_role" TO "authenticated";
GRANT ALL ON TABLE "public"."invite_rbac_role" TO "service_role";



GRANT ALL ON TABLE "public"."link_module_migrations" TO "anon";
GRANT ALL ON TABLE "public"."link_module_migrations" TO "authenticated";
GRANT ALL ON TABLE "public"."link_module_migrations" TO "service_role";



GRANT ALL ON SEQUENCE "public"."link_module_migrations_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."link_module_migrations_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."link_module_migrations_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."location_fulfillment_provider" TO "anon";
GRANT ALL ON TABLE "public"."location_fulfillment_provider" TO "authenticated";
GRANT ALL ON TABLE "public"."location_fulfillment_provider" TO "service_role";



GRANT ALL ON TABLE "public"."location_fulfillment_set" TO "anon";
GRANT ALL ON TABLE "public"."location_fulfillment_set" TO "authenticated";
GRANT ALL ON TABLE "public"."location_fulfillment_set" TO "service_role";



GRANT ALL ON TABLE "public"."mikro_orm_migrations" TO "anon";
GRANT ALL ON TABLE "public"."mikro_orm_migrations" TO "authenticated";
GRANT ALL ON TABLE "public"."mikro_orm_migrations" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mikro_orm_migrations_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mikro_orm_migrations_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mikro_orm_migrations_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."mr_keyword_blacklist" TO "anon";
GRANT ALL ON TABLE "public"."mr_keyword_blacklist" TO "authenticated";
GRANT ALL ON TABLE "public"."mr_keyword_blacklist" TO "service_role";



GRANT ALL ON TABLE "public"."multi_source_eans" TO "anon";
GRANT ALL ON TABLE "public"."multi_source_eans" TO "authenticated";
GRANT ALL ON TABLE "public"."multi_source_eans" TO "service_role";



GRANT ALL ON TABLE "public"."mv_bauhaus_blacklist_eans" TO "anon";
GRANT ALL ON TABLE "public"."mv_bauhaus_blacklist_eans" TO "authenticated";
GRANT ALL ON TABLE "public"."mv_bauhaus_blacklist_eans" TO "service_role";



GRANT ALL ON TABLE "public"."price_snapshots" TO "anon";
GRANT ALL ON TABLE "public"."price_snapshots" TO "authenticated";
GRANT ALL ON TABLE "public"."price_snapshots" TO "service_role";



GRANT ALL ON TABLE "public"."mv_best_deals_by_ean" TO "anon";
GRANT ALL ON TABLE "public"."mv_best_deals_by_ean" TO "authenticated";
GRANT ALL ON TABLE "public"."mv_best_deals_by_ean" TO "service_role";



GRANT ALL ON TABLE "public"."mv_mr_eans" TO "anon";
GRANT ALL ON TABLE "public"."mv_mr_eans" TO "authenticated";
GRANT ALL ON TABLE "public"."mv_mr_eans" TO "service_role";



GRANT ALL ON TABLE "public"."mv_mr_keyword_blacklist_hits" TO "anon";
GRANT ALL ON TABLE "public"."mv_mr_keyword_blacklist_hits" TO "authenticated";
GRANT ALL ON TABLE "public"."mv_mr_keyword_blacklist_hits" TO "service_role";



GRANT ALL ON TABLE "public"."mv_products_current" TO "anon";
GRANT ALL ON TABLE "public"."mv_products_current" TO "authenticated";
GRANT ALL ON TABLE "public"."mv_products_current" TO "service_role";



GRANT ALL ON TABLE "public"."mv_products_unit_price" TO "anon";
GRANT ALL ON TABLE "public"."mv_products_unit_price" TO "authenticated";
GRANT ALL ON TABLE "public"."mv_products_unit_price" TO "service_role";



GRANT ALL ON TABLE "public"."mv_scraping_activity_14d" TO "anon";
GRANT ALL ON TABLE "public"."mv_scraping_activity_14d" TO "authenticated";
GRANT ALL ON TABLE "public"."mv_scraping_activity_14d" TO "service_role";



GRANT ALL ON TABLE "public"."notification" TO "anon";
GRANT ALL ON TABLE "public"."notification" TO "authenticated";
GRANT ALL ON TABLE "public"."notification" TO "service_role";



GRANT ALL ON TABLE "public"."notification_provider" TO "anon";
GRANT ALL ON TABLE "public"."notification_provider" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_provider" TO "service_role";



GRANT ALL ON TABLE "public"."order" TO "anon";
GRANT ALL ON TABLE "public"."order" TO "authenticated";
GRANT ALL ON TABLE "public"."order" TO "service_role";



GRANT ALL ON TABLE "public"."order_address" TO "anon";
GRANT ALL ON TABLE "public"."order_address" TO "authenticated";
GRANT ALL ON TABLE "public"."order_address" TO "service_role";



GRANT ALL ON TABLE "public"."order_cart" TO "anon";
GRANT ALL ON TABLE "public"."order_cart" TO "authenticated";
GRANT ALL ON TABLE "public"."order_cart" TO "service_role";



GRANT ALL ON TABLE "public"."order_change" TO "anon";
GRANT ALL ON TABLE "public"."order_change" TO "authenticated";
GRANT ALL ON TABLE "public"."order_change" TO "service_role";



GRANT ALL ON TABLE "public"."order_change_action" TO "anon";
GRANT ALL ON TABLE "public"."order_change_action" TO "authenticated";
GRANT ALL ON TABLE "public"."order_change_action" TO "service_role";



GRANT ALL ON SEQUENCE "public"."order_change_action_ordering_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."order_change_action_ordering_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."order_change_action_ordering_seq" TO "service_role";



GRANT ALL ON TABLE "public"."order_claim" TO "anon";
GRANT ALL ON TABLE "public"."order_claim" TO "authenticated";
GRANT ALL ON TABLE "public"."order_claim" TO "service_role";



GRANT ALL ON SEQUENCE "public"."order_claim_display_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."order_claim_display_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."order_claim_display_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."order_claim_item" TO "anon";
GRANT ALL ON TABLE "public"."order_claim_item" TO "authenticated";
GRANT ALL ON TABLE "public"."order_claim_item" TO "service_role";



GRANT ALL ON TABLE "public"."order_claim_item_image" TO "anon";
GRANT ALL ON TABLE "public"."order_claim_item_image" TO "authenticated";
GRANT ALL ON TABLE "public"."order_claim_item_image" TO "service_role";



GRANT ALL ON TABLE "public"."order_credit_line" TO "anon";
GRANT ALL ON TABLE "public"."order_credit_line" TO "authenticated";
GRANT ALL ON TABLE "public"."order_credit_line" TO "service_role";



GRANT ALL ON SEQUENCE "public"."order_display_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."order_display_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."order_display_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."order_exchange" TO "anon";
GRANT ALL ON TABLE "public"."order_exchange" TO "authenticated";
GRANT ALL ON TABLE "public"."order_exchange" TO "service_role";



GRANT ALL ON SEQUENCE "public"."order_exchange_display_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."order_exchange_display_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."order_exchange_display_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."order_exchange_item" TO "anon";
GRANT ALL ON TABLE "public"."order_exchange_item" TO "authenticated";
GRANT ALL ON TABLE "public"."order_exchange_item" TO "service_role";



GRANT ALL ON TABLE "public"."order_fulfillment" TO "anon";
GRANT ALL ON TABLE "public"."order_fulfillment" TO "authenticated";
GRANT ALL ON TABLE "public"."order_fulfillment" TO "service_role";



GRANT ALL ON TABLE "public"."order_item" TO "anon";
GRANT ALL ON TABLE "public"."order_item" TO "authenticated";
GRANT ALL ON TABLE "public"."order_item" TO "service_role";



GRANT ALL ON TABLE "public"."order_line_item" TO "anon";
GRANT ALL ON TABLE "public"."order_line_item" TO "authenticated";
GRANT ALL ON TABLE "public"."order_line_item" TO "service_role";



GRANT ALL ON TABLE "public"."order_line_item_adjustment" TO "anon";
GRANT ALL ON TABLE "public"."order_line_item_adjustment" TO "authenticated";
GRANT ALL ON TABLE "public"."order_line_item_adjustment" TO "service_role";



GRANT ALL ON TABLE "public"."order_line_item_tax_line" TO "anon";
GRANT ALL ON TABLE "public"."order_line_item_tax_line" TO "authenticated";
GRANT ALL ON TABLE "public"."order_line_item_tax_line" TO "service_role";



GRANT ALL ON TABLE "public"."order_payment_collection" TO "anon";
GRANT ALL ON TABLE "public"."order_payment_collection" TO "authenticated";
GRANT ALL ON TABLE "public"."order_payment_collection" TO "service_role";



GRANT ALL ON TABLE "public"."order_promotion" TO "anon";
GRANT ALL ON TABLE "public"."order_promotion" TO "authenticated";
GRANT ALL ON TABLE "public"."order_promotion" TO "service_role";



GRANT ALL ON TABLE "public"."order_shipping" TO "anon";
GRANT ALL ON TABLE "public"."order_shipping" TO "authenticated";
GRANT ALL ON TABLE "public"."order_shipping" TO "service_role";



GRANT ALL ON TABLE "public"."order_shipping_method" TO "anon";
GRANT ALL ON TABLE "public"."order_shipping_method" TO "authenticated";
GRANT ALL ON TABLE "public"."order_shipping_method" TO "service_role";



GRANT ALL ON TABLE "public"."order_shipping_method_adjustment" TO "anon";
GRANT ALL ON TABLE "public"."order_shipping_method_adjustment" TO "authenticated";
GRANT ALL ON TABLE "public"."order_shipping_method_adjustment" TO "service_role";



GRANT ALL ON TABLE "public"."order_shipping_method_tax_line" TO "anon";
GRANT ALL ON TABLE "public"."order_shipping_method_tax_line" TO "authenticated";
GRANT ALL ON TABLE "public"."order_shipping_method_tax_line" TO "service_role";



GRANT ALL ON TABLE "public"."order_summary" TO "anon";
GRANT ALL ON TABLE "public"."order_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."order_summary" TO "service_role";



GRANT ALL ON TABLE "public"."order_transaction" TO "anon";
GRANT ALL ON TABLE "public"."order_transaction" TO "authenticated";
GRANT ALL ON TABLE "public"."order_transaction" TO "service_role";



GRANT ALL ON TABLE "public"."payment" TO "anon";
GRANT ALL ON TABLE "public"."payment" TO "authenticated";
GRANT ALL ON TABLE "public"."payment" TO "service_role";



GRANT ALL ON TABLE "public"."payment_collection" TO "anon";
GRANT ALL ON TABLE "public"."payment_collection" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_collection" TO "service_role";



GRANT ALL ON TABLE "public"."payment_collection_payment_providers" TO "anon";
GRANT ALL ON TABLE "public"."payment_collection_payment_providers" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_collection_payment_providers" TO "service_role";



GRANT ALL ON TABLE "public"."payment_provider" TO "anon";
GRANT ALL ON TABLE "public"."payment_provider" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_provider" TO "service_role";



GRANT ALL ON TABLE "public"."payment_session" TO "anon";
GRANT ALL ON TABLE "public"."payment_session" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_session" TO "service_role";



GRANT ALL ON TABLE "public"."price" TO "anon";
GRANT ALL ON TABLE "public"."price" TO "authenticated";
GRANT ALL ON TABLE "public"."price" TO "service_role";



GRANT ALL ON TABLE "public"."price_history" TO "anon";
GRANT ALL ON TABLE "public"."price_history" TO "authenticated";
GRANT ALL ON TABLE "public"."price_history" TO "service_role";



GRANT ALL ON SEQUENCE "public"."price_history_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."price_history_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."price_history_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."price_list" TO "anon";
GRANT ALL ON TABLE "public"."price_list" TO "authenticated";
GRANT ALL ON TABLE "public"."price_list" TO "service_role";



GRANT ALL ON TABLE "public"."price_list_rule" TO "anon";
GRANT ALL ON TABLE "public"."price_list_rule" TO "authenticated";
GRANT ALL ON TABLE "public"."price_list_rule" TO "service_role";



GRANT ALL ON TABLE "public"."price_preference" TO "anon";
GRANT ALL ON TABLE "public"."price_preference" TO "authenticated";
GRANT ALL ON TABLE "public"."price_preference" TO "service_role";



GRANT ALL ON TABLE "public"."price_rule" TO "anon";
GRANT ALL ON TABLE "public"."price_rule" TO "authenticated";
GRANT ALL ON TABLE "public"."price_rule" TO "service_role";



GRANT ALL ON TABLE "public"."price_set" TO "anon";
GRANT ALL ON TABLE "public"."price_set" TO "authenticated";
GRANT ALL ON TABLE "public"."price_set" TO "service_role";



GRANT ALL ON TABLE "public"."product" TO "anon";
GRANT ALL ON TABLE "public"."product" TO "authenticated";
GRANT ALL ON TABLE "public"."product" TO "service_role";



GRANT ALL ON TABLE "public"."product_category" TO "anon";
GRANT ALL ON TABLE "public"."product_category" TO "authenticated";
GRANT ALL ON TABLE "public"."product_category" TO "service_role";



GRANT ALL ON TABLE "public"."product_category_product" TO "anon";
GRANT ALL ON TABLE "public"."product_category_product" TO "authenticated";
GRANT ALL ON TABLE "public"."product_category_product" TO "service_role";



GRANT ALL ON TABLE "public"."product_collection" TO "anon";
GRANT ALL ON TABLE "public"."product_collection" TO "authenticated";
GRANT ALL ON TABLE "public"."product_collection" TO "service_role";



GRANT ALL ON TABLE "public"."product_option" TO "anon";
GRANT ALL ON TABLE "public"."product_option" TO "authenticated";
GRANT ALL ON TABLE "public"."product_option" TO "service_role";



GRANT ALL ON TABLE "public"."product_option_value" TO "anon";
GRANT ALL ON TABLE "public"."product_option_value" TO "authenticated";
GRANT ALL ON TABLE "public"."product_option_value" TO "service_role";



GRANT ALL ON TABLE "public"."product_sales_channel" TO "anon";
GRANT ALL ON TABLE "public"."product_sales_channel" TO "authenticated";
GRANT ALL ON TABLE "public"."product_sales_channel" TO "service_role";



GRANT ALL ON TABLE "public"."product_shipping_profile" TO "anon";
GRANT ALL ON TABLE "public"."product_shipping_profile" TO "authenticated";
GRANT ALL ON TABLE "public"."product_shipping_profile" TO "service_role";



GRANT ALL ON TABLE "public"."product_tag" TO "anon";
GRANT ALL ON TABLE "public"."product_tag" TO "authenticated";
GRANT ALL ON TABLE "public"."product_tag" TO "service_role";



GRANT ALL ON TABLE "public"."product_tags" TO "anon";
GRANT ALL ON TABLE "public"."product_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."product_tags" TO "service_role";



GRANT ALL ON TABLE "public"."product_type" TO "anon";
GRANT ALL ON TABLE "public"."product_type" TO "authenticated";
GRANT ALL ON TABLE "public"."product_type" TO "service_role";



GRANT ALL ON TABLE "public"."product_variant" TO "anon";
GRANT ALL ON TABLE "public"."product_variant" TO "authenticated";
GRANT ALL ON TABLE "public"."product_variant" TO "service_role";



GRANT ALL ON TABLE "public"."product_variant_inventory_item" TO "anon";
GRANT ALL ON TABLE "public"."product_variant_inventory_item" TO "authenticated";
GRANT ALL ON TABLE "public"."product_variant_inventory_item" TO "service_role";



GRANT ALL ON TABLE "public"."product_variant_option" TO "anon";
GRANT ALL ON TABLE "public"."product_variant_option" TO "authenticated";
GRANT ALL ON TABLE "public"."product_variant_option" TO "service_role";



GRANT ALL ON TABLE "public"."product_variant_price_set" TO "anon";
GRANT ALL ON TABLE "public"."product_variant_price_set" TO "authenticated";
GRANT ALL ON TABLE "public"."product_variant_price_set" TO "service_role";



GRANT ALL ON TABLE "public"."product_variant_product_image" TO "anon";
GRANT ALL ON TABLE "public"."product_variant_product_image" TO "authenticated";
GRANT ALL ON TABLE "public"."product_variant_product_image" TO "service_role";



GRANT ALL ON TABLE "public"."products_to_translate" TO "anon";
GRANT ALL ON TABLE "public"."products_to_translate" TO "authenticated";
GRANT ALL ON TABLE "public"."products_to_translate" TO "service_role";



GRANT ALL ON TABLE "public"."promotion" TO "anon";
GRANT ALL ON TABLE "public"."promotion" TO "authenticated";
GRANT ALL ON TABLE "public"."promotion" TO "service_role";



GRANT ALL ON TABLE "public"."promotion_application_method" TO "anon";
GRANT ALL ON TABLE "public"."promotion_application_method" TO "authenticated";
GRANT ALL ON TABLE "public"."promotion_application_method" TO "service_role";



GRANT ALL ON TABLE "public"."promotion_campaign" TO "anon";
GRANT ALL ON TABLE "public"."promotion_campaign" TO "authenticated";
GRANT ALL ON TABLE "public"."promotion_campaign" TO "service_role";



GRANT ALL ON TABLE "public"."promotion_campaign_budget" TO "anon";
GRANT ALL ON TABLE "public"."promotion_campaign_budget" TO "authenticated";
GRANT ALL ON TABLE "public"."promotion_campaign_budget" TO "service_role";



GRANT ALL ON TABLE "public"."promotion_campaign_budget_usage" TO "anon";
GRANT ALL ON TABLE "public"."promotion_campaign_budget_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."promotion_campaign_budget_usage" TO "service_role";



GRANT ALL ON TABLE "public"."promotion_promotion_rule" TO "anon";
GRANT ALL ON TABLE "public"."promotion_promotion_rule" TO "authenticated";
GRANT ALL ON TABLE "public"."promotion_promotion_rule" TO "service_role";



GRANT ALL ON TABLE "public"."promotion_rule" TO "anon";
GRANT ALL ON TABLE "public"."promotion_rule" TO "authenticated";
GRANT ALL ON TABLE "public"."promotion_rule" TO "service_role";



GRANT ALL ON TABLE "public"."promotion_rule_value" TO "anon";
GRANT ALL ON TABLE "public"."promotion_rule_value" TO "authenticated";
GRANT ALL ON TABLE "public"."promotion_rule_value" TO "service_role";



GRANT ALL ON TABLE "public"."property_label" TO "anon";
GRANT ALL ON TABLE "public"."property_label" TO "authenticated";
GRANT ALL ON TABLE "public"."property_label" TO "service_role";



GRANT ALL ON TABLE "public"."provider_identity" TO "anon";
GRANT ALL ON TABLE "public"."provider_identity" TO "authenticated";
GRANT ALL ON TABLE "public"."provider_identity" TO "service_role";



GRANT ALL ON TABLE "public"."publishable_api_key_sales_channel" TO "anon";
GRANT ALL ON TABLE "public"."publishable_api_key_sales_channel" TO "authenticated";
GRANT ALL ON TABLE "public"."publishable_api_key_sales_channel" TO "service_role";



GRANT ALL ON TABLE "public"."refund" TO "anon";
GRANT ALL ON TABLE "public"."refund" TO "authenticated";
GRANT ALL ON TABLE "public"."refund" TO "service_role";



GRANT ALL ON TABLE "public"."refund_reason" TO "anon";
GRANT ALL ON TABLE "public"."refund_reason" TO "authenticated";
GRANT ALL ON TABLE "public"."refund_reason" TO "service_role";



GRANT ALL ON TABLE "public"."refurbished_products" TO "anon";
GRANT ALL ON TABLE "public"."refurbished_products" TO "authenticated";
GRANT ALL ON TABLE "public"."refurbished_products" TO "service_role";



GRANT ALL ON SEQUENCE "public"."refurbished_products_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."refurbished_products_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."refurbished_products_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."region" TO "anon";
GRANT ALL ON TABLE "public"."region" TO "authenticated";
GRANT ALL ON TABLE "public"."region" TO "service_role";



GRANT ALL ON TABLE "public"."region_country" TO "anon";
GRANT ALL ON TABLE "public"."region_country" TO "authenticated";
GRANT ALL ON TABLE "public"."region_country" TO "service_role";



GRANT ALL ON TABLE "public"."region_payment_provider" TO "anon";
GRANT ALL ON TABLE "public"."region_payment_provider" TO "authenticated";
GRANT ALL ON TABLE "public"."region_payment_provider" TO "service_role";



GRANT ALL ON TABLE "public"."reservation_item" TO "anon";
GRANT ALL ON TABLE "public"."reservation_item" TO "authenticated";
GRANT ALL ON TABLE "public"."reservation_item" TO "service_role";



GRANT ALL ON TABLE "public"."return" TO "anon";
GRANT ALL ON TABLE "public"."return" TO "authenticated";
GRANT ALL ON TABLE "public"."return" TO "service_role";



GRANT ALL ON SEQUENCE "public"."return_display_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."return_display_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."return_display_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."return_fulfillment" TO "anon";
GRANT ALL ON TABLE "public"."return_fulfillment" TO "authenticated";
GRANT ALL ON TABLE "public"."return_fulfillment" TO "service_role";



GRANT ALL ON TABLE "public"."return_item" TO "anon";
GRANT ALL ON TABLE "public"."return_item" TO "authenticated";
GRANT ALL ON TABLE "public"."return_item" TO "service_role";



GRANT ALL ON TABLE "public"."return_reason" TO "anon";
GRANT ALL ON TABLE "public"."return_reason" TO "authenticated";
GRANT ALL ON TABLE "public"."return_reason" TO "service_role";



GRANT ALL ON TABLE "public"."sales_channel" TO "anon";
GRANT ALL ON TABLE "public"."sales_channel" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_channel" TO "service_role";



GRANT ALL ON TABLE "public"."sales_channel_stock_location" TO "anon";
GRANT ALL ON TABLE "public"."sales_channel_stock_location" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_channel_stock_location" TO "service_role";



GRANT ALL ON TABLE "public"."scrape_queue" TO "anon";
GRANT ALL ON TABLE "public"."scrape_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."scrape_queue" TO "service_role";



GRANT ALL ON SEQUENCE "public"."scrape_queue_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."scrape_queue_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."scrape_queue_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."scraper_status" TO "anon";
GRANT ALL ON TABLE "public"."scraper_status" TO "authenticated";
GRANT ALL ON TABLE "public"."scraper_status" TO "service_role";



GRANT ALL ON TABLE "public"."scraping_logs" TO "anon";
GRANT ALL ON TABLE "public"."scraping_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."scraping_logs" TO "service_role";



GRANT ALL ON TABLE "public"."script_migrations" TO "anon";
GRANT ALL ON TABLE "public"."script_migrations" TO "authenticated";
GRANT ALL ON TABLE "public"."script_migrations" TO "service_role";



GRANT ALL ON SEQUENCE "public"."script_migrations_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."script_migrations_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."script_migrations_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."secondbuy_products" TO "anon";
GRANT ALL ON TABLE "public"."secondbuy_products" TO "authenticated";
GRANT ALL ON TABLE "public"."secondbuy_products" TO "service_role";



GRANT ALL ON TABLE "public"."secondbuy_stock_history" TO "anon";
GRANT ALL ON TABLE "public"."secondbuy_stock_history" TO "authenticated";
GRANT ALL ON TABLE "public"."secondbuy_stock_history" TO "service_role";



GRANT ALL ON TABLE "public"."service_zone" TO "anon";
GRANT ALL ON TABLE "public"."service_zone" TO "authenticated";
GRANT ALL ON TABLE "public"."service_zone" TO "service_role";



GRANT ALL ON TABLE "public"."shipping_option" TO "anon";
GRANT ALL ON TABLE "public"."shipping_option" TO "authenticated";
GRANT ALL ON TABLE "public"."shipping_option" TO "service_role";



GRANT ALL ON TABLE "public"."shipping_option_price_set" TO "anon";
GRANT ALL ON TABLE "public"."shipping_option_price_set" TO "authenticated";
GRANT ALL ON TABLE "public"."shipping_option_price_set" TO "service_role";



GRANT ALL ON TABLE "public"."shipping_option_rule" TO "anon";
GRANT ALL ON TABLE "public"."shipping_option_rule" TO "authenticated";
GRANT ALL ON TABLE "public"."shipping_option_rule" TO "service_role";



GRANT ALL ON TABLE "public"."shipping_option_type" TO "anon";
GRANT ALL ON TABLE "public"."shipping_option_type" TO "authenticated";
GRANT ALL ON TABLE "public"."shipping_option_type" TO "service_role";



GRANT ALL ON TABLE "public"."shipping_profile" TO "anon";
GRANT ALL ON TABLE "public"."shipping_profile" TO "authenticated";
GRANT ALL ON TABLE "public"."shipping_profile" TO "service_role";



GRANT ALL ON TABLE "public"."stock_location" TO "anon";
GRANT ALL ON TABLE "public"."stock_location" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_location" TO "service_role";



GRANT ALL ON TABLE "public"."stock_location_address" TO "anon";
GRANT ALL ON TABLE "public"."stock_location_address" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_location_address" TO "service_role";



GRANT ALL ON TABLE "public"."store" TO "anon";
GRANT ALL ON TABLE "public"."store" TO "authenticated";
GRANT ALL ON TABLE "public"."store" TO "service_role";



GRANT ALL ON TABLE "public"."store_currency" TO "anon";
GRANT ALL ON TABLE "public"."store_currency" TO "authenticated";
GRANT ALL ON TABLE "public"."store_currency" TO "service_role";



GRANT ALL ON TABLE "public"."store_locale" TO "anon";
GRANT ALL ON TABLE "public"."store_locale" TO "authenticated";
GRANT ALL ON TABLE "public"."store_locale" TO "service_role";



GRANT ALL ON TABLE "public"."tax_provider" TO "anon";
GRANT ALL ON TABLE "public"."tax_provider" TO "authenticated";
GRANT ALL ON TABLE "public"."tax_provider" TO "service_role";



GRANT ALL ON TABLE "public"."tax_rate" TO "anon";
GRANT ALL ON TABLE "public"."tax_rate" TO "authenticated";
GRANT ALL ON TABLE "public"."tax_rate" TO "service_role";



GRANT ALL ON TABLE "public"."tax_rate_rule" TO "anon";
GRANT ALL ON TABLE "public"."tax_rate_rule" TO "authenticated";
GRANT ALL ON TABLE "public"."tax_rate_rule" TO "service_role";



GRANT ALL ON TABLE "public"."tax_region" TO "anon";
GRANT ALL ON TABLE "public"."tax_region" TO "authenticated";
GRANT ALL ON TABLE "public"."tax_region" TO "service_role";



GRANT ALL ON TABLE "public"."technikdirekt_products" TO "anon";
GRANT ALL ON TABLE "public"."technikdirekt_products" TO "authenticated";
GRANT ALL ON TABLE "public"."technikdirekt_products" TO "service_role";



GRANT ALL ON TABLE "public"."user" TO "anon";
GRANT ALL ON TABLE "public"."user" TO "authenticated";
GRANT ALL ON TABLE "public"."user" TO "service_role";



GRANT ALL ON TABLE "public"."user_preference" TO "anon";
GRANT ALL ON TABLE "public"."user_preference" TO "authenticated";
GRANT ALL ON TABLE "public"."user_preference" TO "service_role";



GRANT ALL ON TABLE "public"."user_rbac_role" TO "anon";
GRANT ALL ON TABLE "public"."user_rbac_role" TO "authenticated";
GRANT ALL ON TABLE "public"."user_rbac_role" TO "service_role";



GRANT ALL ON TABLE "public"."v_active_blitzangebote" TO "anon";
GRANT ALL ON TABLE "public"."v_active_blitzangebote" TO "authenticated";
GRANT ALL ON TABLE "public"."v_active_blitzangebote" TO "service_role";



GRANT ALL ON TABLE "public"."v_dashboard_prices" TO "anon";
GRANT ALL ON TABLE "public"."v_dashboard_prices" TO "authenticated";
GRANT ALL ON TABLE "public"."v_dashboard_prices" TO "service_role";



GRANT ALL ON TABLE "public"."v_dashboard_products" TO "anon";
GRANT ALL ON TABLE "public"."v_dashboard_products" TO "authenticated";
GRANT ALL ON TABLE "public"."v_dashboard_products" TO "service_role";



GRANT ALL ON TABLE "public"."v_deals_blacklist_filtered" TO "anon";
GRANT ALL ON TABLE "public"."v_deals_blacklist_filtered" TO "authenticated";
GRANT ALL ON TABLE "public"."v_deals_blacklist_filtered" TO "service_role";



GRANT ALL ON TABLE "public"."v_deals_latest" TO "anon";
GRANT ALL ON TABLE "public"."v_deals_latest" TO "authenticated";
GRANT ALL ON TABLE "public"."v_deals_latest" TO "service_role";



GRANT ALL ON TABLE "public"."v_price_comparison" TO "anon";
GRANT ALL ON TABLE "public"."v_price_comparison" TO "authenticated";
GRANT ALL ON TABLE "public"."v_price_comparison" TO "service_role";



GRANT ALL ON TABLE "public"."v_price_drops" TO "anon";
GRANT ALL ON TABLE "public"."v_price_drops" TO "authenticated";
GRANT ALL ON TABLE "public"."v_price_drops" TO "service_role";



GRANT ALL ON TABLE "public"."v_products_current_enriched" TO "anon";
GRANT ALL ON TABLE "public"."v_products_current_enriched" TO "authenticated";
GRANT ALL ON TABLE "public"."v_products_current_enriched" TO "service_role";



GRANT ALL ON TABLE "public"."v_products_full" TO "anon";
GRANT ALL ON TABLE "public"."v_products_full" TO "authenticated";
GRANT ALL ON TABLE "public"."v_products_full" TO "service_role";



GRANT ALL ON TABLE "public"."v_products_mr_ready" TO "anon";
GRANT ALL ON TABLE "public"."v_products_mr_ready" TO "authenticated";
GRANT ALL ON TABLE "public"."v_products_mr_ready" TO "service_role";



GRANT ALL ON TABLE "public"."view_configuration" TO "anon";
GRANT ALL ON TABLE "public"."view_configuration" TO "authenticated";
GRANT ALL ON TABLE "public"."view_configuration" TO "service_role";



GRANT ALL ON TABLE "public"."workflow_execution" TO "anon";
GRANT ALL ON TABLE "public"."workflow_execution" TO "authenticated";
GRANT ALL ON TABLE "public"."workflow_execution" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







