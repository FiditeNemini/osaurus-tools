---
name: osaurus-search
description: How to use the web search tools. Default to `search(query=...)` — the plugin auto-picks the best backend and races free fallbacks in parallel. Only override defaults when you have a specific reason.
metadata:
  author: Osaurus
  version: "2.1.0"
---

# Search

Web search for grounding. Free by default (DuckDuckGo / Brave / Bing scraping, raced in parallel under a 12s wall-clock budget). Upgrades automatically when an API key (Tavily / Brave Search / Serper / Google CSE / Kagi / You.com) is configured.

## TL;DR

```text
search(query="latest CVEs in nginx")
```

That's it. **Do not** pass `provider`, `region`, `site`, `filetype`, or `offset` unless you have a concrete reason to.

## When to use

- The user asks a factual question that needs current information → `search`.
- The user wants news → `search_news` (defaults to last week).
- The user wants images → `search_images`.
- You want a grounded answer in one round-trip → `search_and_extract` (does search + Readability).
- You need URLs to feed to `osaurus.fetch.fetch_html` for deep extraction → `search`.

## When NOT to use

- Reading a *known* URL → go straight to `osaurus.fetch.fetch_html`.
- Searching the user's own files → use the host's working-folder search.
- Real-time stock / weather / sports → those want a dedicated API.

## Canonical recipes

Grounded research:

```text
1. search(query="...", time_range="m")
2. for each result.url: osaurus.fetch.fetch_html(url) → markdown
3. Synthesize from the markdowns; cite final_url + published_date.
```

One-shot grounded answer:

```text
search_and_extract(query="...", max_results=5, extract_count=3)
→ results[].markdown is already populated for the top extract_count hits
```

## Output envelope

Success:

```json
{
  "ok": true,
  "data": {
    "query": "...",
    "provider": "ddg",
    "results": [
      {
        "rank": 1,
        "title": "...",
        "url": "https://...",
        "snippet": "...",
        "published_date": "2026-04-15",
        "source_domain": "example.com",
        "engine": "ddg"
      }
    ],
    "count": 10,
    "next_offset": 10,
    "attempts": [{"provider": "ddg", "ok": true, "count": 10}]
  },
  "warnings": ["Ignored unknown provider 'auto'; used auto-cascade. ..."]
}
```

Failure:

```json
{
  "ok": false,
  "error": {
    "code": "NO_RESULTS",
    "message": "No results from any backend.",
    "hint": "Try a broader query, drop site:/filetype:/time_range, or configure a paid API key (e.g. TAVILY_API_KEY) in plugin settings."
  },
  "data": { "attempts": [...], "warnings": [...] }
}
```

Error codes you may see: `INVALID_ARGS`, `NO_RESULTS`, `PROVIDER_UNAVAILABLE`, `INTERNAL`.

## Tips

- **Don't splice operators into the query.** `site:` and `filetype:` translate per-backend; pass them as their own params if you really need them.
- **Don't pin a provider unless you have to.** Auto-cascade already prefers any configured paid backend (Tavily > Brave API > Serper > Google CSE > Kagi > You.com), then races free scrapers in parallel.
- **Paginate** with `offset` rather than re-querying for more.
- Snippets vary in quality across providers. For full text, follow up with `osaurus.fetch.fetch_html` on the top URLs (or just call `search_and_extract`).

## Advanced: better quality with API keys

Configure any of these in the plugin's secrets settings to upgrade from scraping to grounded API search:

- `TAVILY_API_KEY` — Tavily (best free agent search; 1000 free queries/month)
- `BRAVE_SEARCH_API_KEY` — Brave Search API
- `SERPER_API_KEY` — Serper (Google SERP)
- `GOOGLE_CSE_API_KEY` + `GOOGLE_CSE_CX` — Google Custom Search Engine
- `KAGI_API_KEY` — Kagi
- `YOU_API_KEY` — You.com

Once a key is set, the plugin auto-uses it; no code or argument changes required.

## Advanced: pinning a backend

If you really need to pin one (e.g. comparing snippet quality, or sidestepping a flaky scraper):

```text
search(query="...", provider="ddg")
```

Valid `provider` values: `tavily`, `brave_api`, `serper`, `google_cse`, `kagi`, `you`, `ddg`, `brave_html`, `bing_html`. Anything else is silently ignored with a `warnings` entry.
