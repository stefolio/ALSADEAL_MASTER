-- RPC pour remplacer Meilisearch sur le browsing deals
-- Utilise products directement (pas de MV), filtre par name_fr, prix >= 10, mr_compatible
-- Supporte pagination, catégorie, tri par écart %

CREATE OR REPLACE FUNCTION public.get_deals_page_full(
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20,
  p_min_sources integer DEFAULT 2,
  p_price_min numeric DEFAULT 10,
  p_price_max numeric DEFAULT NULL::numeric,
  p_category text DEFAULT NULL
)
RETURNS TABLE(
  ean text,
  id uuid,
  name_fr text,
  name text,
  image_url text,
  brand_name text,
  source text,
  product_url text,
  sku text,
  condition text,
  grade text,
  best_price numeric,
  max_price numeric,
  discount_pct numeric,
  sources_count bigint,
  total_count bigint
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_page integer := GREATEST(1, COALESCE(p_page, 1));
  v_size integer := GREATEST(1, LEAST(200, COALESCE(p_page_size, 20)));
  v_offset integer := (v_page - 1) * v_size;
BEGIN
  RETURN QUERY
  WITH ean_stats AS (
    SELECT
      p.ean,
      COUNT(DISTINCT p.source)::bigint AS sources_count,
      MIN(p.price) AS min_price,
      MAX(p.price) AS max_price,
      ROUND((MAX(p.price) - MIN(p.price)) / NULLIF(MAX(p.price), 0) * 100, 1) AS discount_pct
    FROM products p
    WHERE p.ean IS NOT NULL AND p.ean <> ''
      AND p.price >= COALESCE(p_price_min, 0)
      AND (p_price_max IS NULL OR p.price <= p_price_max)
      AND p.in_stock = true
      AND COALESCE(p.mr_compatible, false) = true
      AND p.name_fr IS NOT NULL
      AND (p_category IS NULL OR p.category_main = p_category OR p.category = p_category)
    GROUP BY p.ean
    HAVING COUNT(DISTINCT p.source) >= GREATEST(1, COALESCE(p_min_sources, 2))
  ),
  all_count AS (
    SELECT COUNT(*)::bigint AS cnt FROM ean_stats
  ),
  ranked AS (
    SELECT ean, sources_count, min_price, max_price, discount_pct
    FROM ean_stats
    ORDER BY discount_pct DESC, min_price ASC, ean ASC
    OFFSET v_offset
    LIMIT v_size
  ),
  best_products AS (
    SELECT DISTINCT ON (r.ean)
      r.ean, p.id, p.name_fr, p.name,
      COALESCE(p.image_r2_url, p.image_url) AS image_url,
      p.brand_name, p.source, p.product_url, p.sku,
      p.condition, p.grade, p.price,
      r.sources_count, r.discount_pct, r.max_price
    FROM ranked r
    JOIN products p ON p.ean = r.ean
    WHERE p.name_fr IS NOT NULL AND p.price >= COALESCE(p_price_min, 0)
    ORDER BY r.ean, p.price ASC, p.id
  )
  SELECT
    bp.ean, bp.id, bp.name_fr, bp.name, bp.image_url,
    bp.brand_name, bp.source, bp.product_url, bp.sku,
    bp.condition, bp.grade, bp.price AS best_price,
    bp.max_price, bp.discount_pct, bp.sources_count,
    (SELECT cnt FROM all_count) AS total_count
  FROM best_products bp
  ORDER BY bp.discount_pct DESC, bp.price ASC, bp.ean ASC;
END;
$$;

GRANT ALL ON FUNCTION public.get_deals_page_full(
  integer, integer, integer, numeric, numeric, text
) TO anon, authenticated, service_role;
