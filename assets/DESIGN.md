# ALSADEAL Design System

## Brand Identity

ALSADEAL est un comparateur de prix / marketplace basé en Alsace. La cigogne alsacienne en vol, tenant un « deal » dans son bec, symbolise la livraison rapide des bonnes affaires.

- **Logo horizontal** : utilisation prioritaire, ratio ~3:1
- **Couleurs** : Rouge Alsace (#E30613), Blanc, Noir
- **Ton** : professionnel, confiant, légèrement régional
- **Usage** : e-commerce outillage + hardware + marketplace généraliste

---

## Color Palette

### Light Mode

| Token | Hex | Usage |
|-------|-----|-------|
| `--color-bg` | `#FFFFFF` | Fond principal |
| `--color-bg-secondary` | `#F5F5F7` | Fond alterné / cartes |
| `--color-bg-tertiary` | `#E8E8ED` | Hover surfaces |
| `--color-text` | `#1A1A1A` | Texte principal |
| `--color-text-secondary` | `#6B6B7B` | Texte secondaire |
| `--color-text-tertiary` | `#9E9EB0` | Texte subtil / labels |
| `--color-primary` | `#E30613` | Rouge Alsace — CTAs, liens, badges |
| `--color-primary-hover` | `#C00510` | Hover primary |
| `--color-primary-light` | `#FFF0F0` | Surfaces primaires légères |
| `--color-border` | `#E0E0E6` | Bordures |
| `--color-success` | `#2E7D32` | Vert stock / succès |
| `--color-warning` | `#ED6C02` | Orange avertissement |
| `--color-error` | `#D32F2F` | Rouge erreur |

### Dark Mode

| Token | Hex | Usage |
|-------|-----|-------|
| `--color-bg` | `#121212` | Fond principal |
| `--color-bg-secondary` | `#1E1E24` | Fond alterné / cartes |
| `--color-bg-tertiary` | `#2C2C36` | Hover surfaces |
| `--color-text` | `#F5F5F7` | Texte principal |
| `--color-text-secondary` | `#A0A0B0` | Texte secondaire |
| `--color-text-tertiary` | `#707080` | Texte subtil / labels |
| `--color-primary` | `#FF453A` | Rouge Alsace (adapté dark) |
| `--color-primary-hover` | `#FF6B5E` | Hover primary |
| `--color-primary-light` | `#2D1515` | Surfaces primaires légères |
| `--color-border` | `#333340` | Bordures |
| `--color-success` | `#34C759` | Vert stock / succès |
| `--color-warning` | `#FF9500` | Orange avertissement |
| `--color-error` | `#FF3B30` | Rouge erreur |

---

## Typography

- **Titres display** : `"Instrument Serif", Georgia, serif` — pour les hero et titres majeurs
- **Titres courants** : `"Inter", "SF Pro", -apple-system, sans-serif` — titres de section, cards
- **Corps** : `"Inter", "SF Pro", -apple-system, sans-serif`
- **Mono** : `"JetBrains Mono", "SF Mono", monospace` — prix, codes, données techniques

| Level | Size | Weight | Line Height | Letter Spacing |
|-------|------|--------|-------------|---------------|
| Display XL | 4.5rem (72px) | 400 | 1.05 | -0.02em |
| Display L | 3rem (48px) | 400 | 1.1 | -0.01em |
| Heading 1 | 2.25rem (36px) | 600 | 1.15 | -0.01em |
| Heading 2 | 1.75rem (28px) | 600 | 1.2 | 0 |
| Heading 3 | 1.375rem (22px) | 600 | 1.25 | 0 |
| Heading 4 | 1.125rem (18px) | 600 | 1.3 | 0 |
| Body Large | 1.0625rem (17px) | 400 | 1.5 | 0 |
| Body | 0.9375rem (15px) | 400 | 1.5 | 0 |
| Body Small | 0.8125rem (13px) | 400 | 1.45 | 0 |
| Caption | 0.75rem (12px) | 400 | 1.4 | 0.01em |
| Price | 1.5rem (24px) | 700 | 1.1 | -0.01em |
| Price Small | 1rem (16px) | 700 | 1.1 | -0.01em |

---

## Component Styles

### Buttons

| Prop | Primary | Secondary | Ghost |
|------|---------|-----------|-------|
| Background | `--color-primary` | transparent | transparent |
| Border | none | `1px solid --color-border` | none |
| Text | white | `--color-text` | `--color-text-secondary` |
| Padding H | 1.5rem (24px) | 1.25rem (20px) | 0.75rem (12px) |
| Padding V | 0.625rem (10px) | 0.5rem (8px) | 0.375rem (6px) |
| Radius | 8px | 8px | 6px |
| Font | Body, 600 | Body, 500 | Body Small, 500 |
| Hover | `--color-primary-hover` | `--color-bg-tertiary` | `--color-bg-tertiary` |
| Transition | all 0.15s ease | all 0.15s ease | all 0.15s ease |

### Cards (Product Cards)

| Prop | Value |
|------|-------|
| Background | `--color-bg-secondary` |
| Radius | 12px |
| Border | `1px solid --color-border` |
| Shadow | `0 1px 3px rgba(0,0,0,0.06)` |
| Hover Shadow | `0 4px 12px rgba(0,0,0,0.1)` |
| Padding | 1rem (16px) |
| Transition | all 0.2s ease |

### Inputs & Forms

| Prop | Value |
|------|-------|
| Background | `--color-bg` |
| Border | `1px solid --color-border` |
| Radius | 8px |
| Padding H | 0.875rem (14px) |
| Padding V | 0.625rem (10px) |
| Font | Body, 400 |
| Focus Border | `--color-primary` |
| Focus Shadow | `0 0 0 3px rgba(227, 6, 19, 0.12)` |
| Placeholder | `--color-text-tertiary` |
| Label | Body Small, 600, margin-bottom 6px |

### Navigation

| Prop | Value |
|------|-------|
| Background | `--color-bg` (with backdrop-blur) |
| Border Bottom | `1px solid --color-border` |
| Link Padding | 0.5rem 1rem |
| Link Active | `--color-primary`, 600 |
| Link Default | `--color-text-secondary`, 400 |
| Height | 64px (mobile: 56px) |
| Logo Height | 32px (mobile: 28px) |

### Badges & Tags

| Prop | Value |
|------|-------|
| Radius | 6px (ou pill: 999px) |
| Padding H | 0.5rem (8px) |
| Padding V | 0.125rem (2px) |
| Font | Caption, 500 |
| Sale Badge | `--color-primary`, white text |
| Stock Badge | `--color-success`, white text |
| Category Tag | `--color-bg-tertiary`, `--color-text-secondary` |

---

## Layout

### Spacing Scale

| Token | Value |
|-------|-------|
| `--space-1` | 4px |
| `--space-2` | 8px |
| `--space-3` | 12px |
| `--space-4` | 16px |
| `--space-5` | 24px |
| `--space-6` | 32px |
| `--space-7` | 48px |
| `--space-8` | 64px |
| `--space-9` | 96px |

### Grid

- **Products grid** : `repeat(auto-fill, minmax(280px, 1fr))` gap `--space-5`
- **Content max-width** : 1280px (1600px pour dashboard)
- **Section padding** : `--space-8` vertical, `--space-5` horizontal (mobile: `--space-5` vertical, `--space-4` horizontal)
- **Gutter** : 24px desktop, 16px tablet, 12px mobile

### Breakpoints

| Name | Width |
|------|-------|
| Mobile | < 640px |
| Tablet | 640px – 1024px |
| Desktop | > 1024px |

---

## Light / Dark Mode Strategy

- Mode par défaut : suit `prefers-color-scheme`
- Toggle manuel disponible (icône soleil/lune dans la nav)
- Transitions CSS : `color 0.2s ease, background-color 0.2s ease`
- Images/logos : utiliser des SVG avec CSS variables pour s'adapter aux deux modes
- Ombres en dark mode : préférer des bordures plutôt que des ombres fortes

---

## Do's and Don'ts

| Do | Don't |
|----|-------|
| Utiliser le rouge avec parcimonie (CTAs, badges, 5-10% max) | Peindre des sections entières en rouge |
| Laisser respirer le blanc / noir | Tasser le contenu |
| Arrondir légèrement les coins (8-12px) | Utiliser des angles vifs ou des radius > 20px |
| Garder une hiérarchie claire | Mélanger les polices serif et sans-serif sur un même bloc |
| Privilégier la lisibilité (contraste) | Utiliser du gris clair sur fond blanc pour le texte |

---

## Agent Prompt Guide

```
Tu suis le DESIGN.md du projet ALSADEAL.

Palette : rouge (#E30613 / #FF453A dark), blanc, noir.
Police : Instrument Serif (display), Inter (corps).
Style : propre, professionnel, e-commerce, avec une singularité régionale alsacienne.

Le logo est une cigogne en vol tenant un cadeau dans son bec.
Toujours prévoir les modes light ET dark.
Le rouge est un accent, pas une couleur de fond.
```
