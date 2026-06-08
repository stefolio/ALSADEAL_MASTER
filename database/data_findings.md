# ALSADEAL — Findings & Diagnostics
# Analyse de la base de données Supabase
# Date du snapshot : 2026-06-08

---

## 🔴 PROBLÈMES CRITIQUES

### 1. Scraper Alternate — Status "partial" en boucle
**Table concernée :** `scraping_logs`
**Symptôme :**
- Le scraper `alternate` tourne toutes les ~30 minutes
- Il trouve toujours exactement **96 produits**
- Il crée **0 nouveau produit** et **0 mise à jour**
- Status : `partial` (jamais `success`)
- `pages_scraped = 0` alors que `products_found = 96`

**Hypothèses :**
- Le scraper est bloqué sur une pagination
- Il re-scrape toujours la même page (page 1)
- Un anti-scraping bloque les pages suivantes
- La logique de déduplication empêche les insertions

**Action requise :**
- Vérifier le code du scraper `alternate` dans VPS2
- Vérifier les logs PM2 : `pm2 logs alternate`
- Vérifier si le site alternate.de a changé sa structure HTML

---

### 2. name_fr = NULL sur la majorité des produits
**Table concernée :** `products`
**Symptôme :**
- La colonne `name_fr` est NULL sur tous les produits testés
- La traduction DE→FR via Amazon Bedrock ne semble pas s'exécuter
- La colonne `translated_at` est NULL aussi

**Impact :**
- Les produits ne peuvent pas être affichés correctement en français
- Le storefront Medusa affiche des noms allemands ou vides
- Les clients FR ne peuvent pas trouver les produits

**Action requise :**
- Vérifier le script de traduction sur VPS1
- Vérifier les crédits Amazon Bedrock
- Vérifier les logs PM2 du traducteur : `pm2 logs translator`
- Vérifier si la file d'attente `products_to_translate` est traitée

---

### 3. medusa_id = NULL sur la majorité des produits
**Table concernée :** `products`
**Symptôme :**
- La colonne `medusa_id` est NULL sur presque tous les produits testés
- Les produits ne sont pas synchronisés vers Medusa
- Le storefront n'a donc rien à afficher

**Impact :**
- C'est LA cause principale du manque de deals visibles
- Même si les scrapers tournent, les produits ne remontent pas sur le shop

**Action requise :**
- Vérifier le script `sync_medusa.py` sur VPS2
- Vérifier les logs : `pm2 logs sync_medusa`
- Vérifier si Medusa tourne bien : `curl localhost:9000/health`
- Vérifier les critères de sélection du script de sync

---

### 4. multi_source_eans.source_count = NULL
**Table concernée :** `multi_source_eans`
**Symptôme :**
- La colonne `source_count` est NULL pour beaucoup d'EAN
- Le système ne "voit" pas combien de fournisseurs vendent le même produit

**Impact :**
- Impossible de calculer le meilleur prix entre fournisseurs
- Impossible de générer des deals multi-sources
- La table `fr_price_comparisons` est vide (conséquence directe)

**Action requise :**
- Vérifier le script qui alimente `source_count`
- Relancer manuellement la mise à jour de cette table
- Vérifier si une vue ou une fonction calcule ce champ

---

### 5. fr_price_comparisons = vide
**Table concernée :** `fr_price_comparisons`
**Symptôme :**
- Table complètement vide
- Aucune comparaison de prix FR calculée

**Impact :**
- Impossible de savoir si ton prix est compétitif vs Amazon FR
- Impossible de calculer les marges réelles

**Dépendance :**
- Cette table dépend de `multi_source_eans` et de `products`
- Elle sera vide tant que les problèmes 3 et 4 ne sont pas résolus

---

## 🟡 PROBLÈMES MOYENS

### 6. scraper_status — Données périmées (avril 2026)
**Table concernée :** `scraper_status`
**Symptôme :**
- Tous les `updated_at` datent d'avril 2026
- Cette table ne se met plus à jour
- Elle ne reflète plus la réalité des scrapers actifs

**Observation :**
- En contradiction avec `scraping_logs` qui montre de l'activité en juin
- `bauportal`, `contorion`, `technikdirekt`, `secondbuy` scrapent activement
- `scraper_status` ne le voit pas

**Action requise :**
- Vérifier le script qui met à jour `scraper_status`
- Peut-être que le nom des sources a changé
- Recalibrer les sources enregistrées dans cette table

---

### 7. technikdirekt — price_num = NULL
**Table concernée :** `technikdirekt_products`
**Symptôme :**
- La colonne `price` est renseignée (ex: 55.68)
- Mais `price_num` est NULL partout
- Colonne dupliquée non alimentée

**Action requise :**
- Vérifier si `price_num` est utilisé quelque part dans le code
- Si oui : ajouter la logique de copie dans le scraper
- Si non : supprimer la colonne (nettoyage)

---

### 8. hardware_online — image_url relative
**Table concernée :** `hardware_online_products`
**Symptôme :**
- `image_url` contient des URLs relatives : `/cdn-cgi/imagedelivery/...`
- Pas de domaine = images non affichables hors du site source

**Action requise :**
- Corriger le scraper pour stocker l'URL complète
- Ajouter le préfixe : `https://www.hardware-online-shop.de`

---

### 9. EAN manquants sur les produits reconditionnés
**Tables concernées :** `secondbuy_products`, `hardware_online_products`
**Symptôme :**
- EAN = NULL sur pratiquement tous les produits reconditionnés
- Identification par SKU uniquement

**Impact :**
- Impossible de croiser avec `products` (neufs) par EAN
- Impossible de comparer prix neuf vs reconditionné par EAN

**Action requise :**
- Enrichir les produits reconditionnés avec EAN via API externe
  (ex: Open Food Facts, Barcodelookup, ou scraping Amazon par nom)
- Ou accepter que le reconditionné soit un catalogue séparé (non comparé)

---

### 10. mr_keyword_blacklist — Doublons casse
**Table concernée :** `mr_keyword_blacklist`
**Symptôme :**
- Même mot en majuscule et minuscule : `Backofen` ET `backofen`
- Doublons qui alourdissent inutilement la table

**Action requise :**
- Normaliser en lowercase à l'insertion
- Ajouter une contrainte UNIQUE sur `LOWER(keyword)`
- Nettoyer les doublons existants

---

## 🟢 CE QUI FONCTIONNE BIEN

| Source | Status | Dernière activité |
|---|---|---|
| bauportal | ✅ Actif | Juin 2026 |
| contorion | ✅ Actif | Juin 2026 |
| secondbuy | ✅ Actif | Juin 2026 |
| technikdirekt | ✅ Actif | Juin 2026 |
| hardware_online | ✅ Actif | Juin 2026 |
| alternate | ⚠️ Partiel | Juin 2026 (mais 0 nouveaux) |

---

## 📊 VOLUME DE DONNÉES

| Table | Taille | Observations |
|---|---|---|
| products | 3945 MB | Table centrale — très volumineuse |
| price_snapshots | 1324 MB | Historique des prix — à surveiller |
| price_history | 235 MB | En croissance |
| secondbuy_products | 106 MB | Reconditionné actif |
| refurbished_products | 120 MB | Reconditionné global |
| bauportal_products | 59 MB | Neufs actif |
| technikdirekt_products | 61 MB | Neufs actif |
| contorion_products | 36 MB | Neufs actif |
| scrape_queue | 47 MB | File d'attente — à monitorer |
| deals_ean_blacklist | 5656 kB | Blacklist importante |

---

## 🎯 PRIORITÉS D'ACTION

### Priorité 1 — Impact immédiat sur les deals
1. Relancer `sync_medusa.py` (medusa_id = NULL)
2. Relancer le traducteur DE→FR (name_fr = NULL)
3. Corriger le scraper `alternate` (partial en boucle)

### Priorité 2 — Impact sur la qualité des données
4. Recalculer `multi_source_eans.source_count`
5. Corriger `hardware_online` image_url relative
6. Corriger `technikdirekt` price_num NULL

### Priorité 3 — Nettoyage et optimisation
7. Dédupliquer `mr_keyword_blacklist`
8. Recalibrer `scraper_status`
9. Stratégie EAN pour le reconditionné

---

## 💡 POUR L'IA (OpenCode / Graphify)

Quand tu analyses ce projet, priorise ces fichiers :
- Le script de sync Medusa (`sync_medusa.py` sur VPS2)
- Le script de traduction (`translator` sur VPS1)
- Le scraper `alternate` sur VPS2
- La logique de calcul de `multi_source_eans`
- La vue `v_deals_latest` (comment sont sélectionnés les deals ?)