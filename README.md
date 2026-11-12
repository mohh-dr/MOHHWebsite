# MOHH DR static site
Static backup of www.mohh.com.sg on GitHub Pages, refreshed every Monday 02:00 SGT.

- Pages to mirror: `scripts/urls.txt`
- Sync logic: `scripts/crawl.sh` (aborts without publishing if any page is missing)
- Schedule: `.github/workflows/weekly-sync.yml` (also runnable via Actions → Run workflow)
- Test URL: https://mohh-dr.github.io/mohh-dr/
