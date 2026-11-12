# MOHH DR static site
Static backup of www.mohh.com.sg on GitHub Pages, refreshed every Monday 02:00 SGT.

- Pages to mirror: `scripts/urls.txt`
- Sync logic: `scripts/crawl.sh` (deduplicates the page list, rewrites mirrored page links to clean extensionless URLs, marks pages `noindex`, downloads page assets plus navigation, carousel, and media-search data/assets, and retains GitHub-only files; aborts if a required page or asset is missing)
- Schedule: `.github/workflows/weekly-sync.yml` (also runnable via Actions → Run workflow)
- Test URL: https://mohh-dr.github.io/mohh-dr/
