# Website / GitHub Pages root

This folder is the website, served by GitHub Pages at
https://clipdiary.app/ (the `CNAME` file binds the custom domain; the Pages
source is `main` + `/docs`).

- `index.html` — the landing page (a comment at its top documents how
  `og.jpg`, the link-preview card, is regenerated).
- `1-second-everyday-alternative-for-mac/` — the guide for people switching
  from 1SE.
- `robots.txt` / `sitemap.xml` — search-engine plumbing.
- `appcast.xml` — the Sparkle update feed the app checks. Regenerated and
  committed by the release workflow (`.github/workflows/release.yml`), not
  edited by hand.
