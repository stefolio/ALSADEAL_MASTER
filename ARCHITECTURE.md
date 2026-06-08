# ALSADEAL — Architecture Globale du Système

## 🎯 Concept Métier
Comparateur de deals multi-fournisseurs avec vente en semi-dropshipping 
via MedusaJS (sans stock physique).
- Les scrapers collectent les prix par EAN chez plusieurs fournisseurs
- Les meilleurs deals sont exposés via le storefront Medusa
- Supabase est le BUS CENTRAL unique entre tous les VPS

---

## 🌐 Architecture Globale
┌─────────────────────────────────────────────────────────────┐
│ VPS1 │
│ 22 scrapers Python (neufs) + Dashboard Next.js :3000 │
│ Traduction DE→FR (Amazon Bedrock/Pixtral Large) │
│ Upload images → Cloudflare R2 │
└──────────────────────────┬──────────────────────────────────┘
│
┌─────────────────────────────────────────────────────────────┐
│ VPS2 │
│ Medusa v2.14 :9000 + Storefront Next.js :8000 │
│ 6 scrapers reconditionnés + Meilisearch :7700 │
│ Stripe + Scripts sync Supabase→Medusa │
└──────────────────────────┬──────────────────────────────────┘
│
┌─────────────────────────────────────────────────────────────┐
│ VPS3 │
│ Backup/Référence de VPS2 │
│ Structure identique (Medusa, scrapers, scripts) │
└──────────────────────────┬──────────────────────────────────┘
│
┌─────────────────────────────────────────────────────────────┐
│ VPS4 │
│ Scraper dédié Retoura/B-Ware (16 catégories) │
│ Écrit dans refurbished_products sur Supabase │
└──────────────────────────┬──────────────────────────────────┘
│
┌──────▼──────┐
│ SUPABASE │
│ PostgreSQL │ ← BUS CENTRAL UNIQUE
│ │
│ Tables : │
│ products │ ← scrapers neufs (VPS1/2)
│ refurbished│ ← scrapers reconditionnés
└─────────────┘

text


---

## 📦 VPS1 — Collecte Neufs + Dashboard Admin

### Rôle
- Scraping de produits NEUFS chez 22 fournisseurs
- Traduction automatique DE→FR via Amazon Bedrock (Pixtral Large)
- Upload et gestion des images produits vers Cloudflare R2
- Dashboard d'administration Next.js (port 3000)

### Technologies
- **Python** : cloudscraper, BeautifulSoup4, requests
- **Next.js 15** : Dashboard admin
- **PM2** : Gestionnaire de processus pour les scrapers
- **Supabase** : Écriture dans la table `products`
- **Amazon Bedrock** : Traduction DE→FR
- **Cloudflare R2** : Stockage des images produits

### Fournisseurs scrapés (neufs)
Bauhaus, Voelkner, Proshop + 19 autres fournisseurs

### Communication
- ✅ Écrit dans Supabase (`products`)
- ✅ Lit depuis Supabase (Dashboard stats)
- ✅ Upload vers Cloudflare R2
- ✅ Appel Amazon Bedrock (traduction)
- ❌ Pas de communication HTTP directe avec les autres VPS

---

## 📦 VPS2 — E-commerce Medusa (Production)

### Rôle
- Plateforme e-commerce complète en semi-dropshipping
- Scraping de produits RECONDITIONNÉS (6 fournisseurs)
- Synchronisation Supabase → Medusa
- Exposition des produits aux clients via Storefront

### Technologies
- **Medusa v2.14** : Backend e-commerce (port 9000)
- **Next.js 15** : Storefront client (port 8000)
- **Meilisearch** : Moteur de recherche (port 7700)
- **Stripe** : Paiement
- **TurboRepo** : Monorepo management
- **Python** : Scrapers + scripts de sync

### Fournisseurs scrapés (reconditionnés)
Alternate, Contorion + 4 autres fournisseurs

### Communication
- ✅ Lit depuis Supabase (`refurbished`, `products`)
- ✅ Sync Supabase → Medusa via script Python local
- ✅ Communication interne : sync_medusa.py → localhost:9000
- ✅ Medusa → Storefront (localhost:8000)
- ❌ Pas de communication HTTP directe avec VPS1/3/4

---

## 📦 VPS3 — Backup de Référence VPS2

### Rôle
- Copie de sauvegarde et de référence de VPS2
- Environnement de test/staging

### Technologies
- Identiques à VPS2 (Medusa, Next.js, Python, scrapers)

### Communication
- ✅ Supabase (même base que VPS2)

---

## 📦 VPS4 — Scraper Retoura B-Ware

### Rôle
- Scraper dédié au site shop.retoura.de
- Collecte de produits reconditionnés/B-Ware
- 16 catégories scrapées
- D'autres scrapers seront ajoutés prochainement

### Technologies
- **Python** : requests, BeautifulSoup4
- **PM2** : Gestionnaire de processus

### Communication
- ✅ Écrit dans Supabase (`refurbished_products`)
- ❌ Pas de communication HTTP avec les autres VPS

---

## 🗄️ Supabase — Base de Données Centrale

### Projet
- **Nom** : Alsadeals
- **Usage** : Database Only (PostgreSQL pur)
- **Host** : db.zitgppbkniobvzfuhyki.supabase.co
- **Auth** : Non utilisé (0 users)
- **Storage** : Non utilisé (0 buckets)

### Tables Principales

#### `products`
- **Remplie par** : Scrapers VPS1 (22 fournisseurs, neufs)
- **Lue par** : Dashboard VPS1, Medusa VPS2
- **Contenu** : Deals de produits neufs identifiés par EAN

#### `refurbished` / `refurbished_products`
- **Remplie par** : Scrapers VPS2 (6 fournisseurs) + VPS4 (Retoura)
- **Lue par** : Medusa VPS2
- **Contenu** : Deals de produits reconditionnés par EAN

---

## 🔄 Règle Fondamentale de Communication

> **Les VPS ne se parlent JAMAIS en HTTP direct.**
> **Supabase (PostgreSQL) est le seul bus de communication inter-VPS.**
VPS1 ──写──→ Supabase ←──读── VPS2 (Medusa)
VPS2 ──写──→ Supabase
VPS4 ──写──→ Supabase ←──读── VPS2 (Medusa)
VPS1 ──读──→ Supabase (Dashboard stats)

text


Communication INTRA-VPS uniquement en HTTP local :
- `sync_medusa.py → localhost:9000` (VPS2 uniquement)

---

## 🔑 Services Externes

| Service | Usage | VPS concerné |
|---|---|---|
| Supabase PostgreSQL | Base centrale | Tous |
| Cloudflare R2 | Stockage images | VPS1 |
| Amazon Bedrock | Traduction DE→FR | VPS1 |
| Stripe | Paiements | VPS2 |
| Meilisearch | Recherche produits | VPS2 |

---

## 📁 Structure du Master Repository
ALSADEAL_MASTER/
├── alsadeal_vps1/ → Scrapers neufs + Dashboard
├── alsadeal_vps2/ → Medusa + Scrapers reconditionnés
├── alsadeal_vps3/ → Backup VPS2
├── alsadeal_vps4-/ → Scraper Retoura
├── database/
│ ├── schema.sql → Schéma PostgreSQL Supabase
│ └── types.ts → Types TypeScript générés
└── ARCHITECTURE.md → Ce fichier

text


---

## 🧠 Pour l'IA (OpenCode / Graphify)

Quand tu analyses ce projet :
- Chaque scraper Python écrit dans Supabase via le client `supabase-py`
- Le lien entre les VPS se fait UNIQUEMENT par les tables Supabase
- `products` = neufs, `refurbished`/`refurbished_products` = reconditionnés
- Le Dashboard (VPS1) et Medusa (VPS2) sont les deux points de lecture
- Les EAN sont la clé de déduplication entre fournisseurs

