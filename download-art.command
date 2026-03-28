#!/bin/bash
cd "$(dirname "$0")"
echo "================================================"
echo "  VINYL VAULT — Album Art Downloader"
echo "  Sources: MusicBrainz / Cover Art Archive"
echo "================================================"
echo ""

python3 - <<'PYEOF'
import json, urllib.request, urllib.parse, urllib.error, time, os, re, sys

ART_DIR = 'art'
os.makedirs(ART_DIR, exist_ok=True)

with open('albums.json', 'r') as f:
    albums = json.load(f)

def safe_filename(artist, album):
    s = f"{artist} - {album}"
    s = re.sub(r'[^\w\s\-]', '', s).strip()
    s = re.sub(r'\s+', '_', s)
    return s[:80] + '.jpg'

MB_HEADERS = {
    'User-Agent': 'VinylVault/1.0 (personal vinyl collection tracker)',
    'Accept': 'application/json'
}

def mb_search(artist, album, year=None):
    """Search MusicBrainz for a release-group and return its MBID."""
    # Build a targeted Lucene query
    q = f'artist:"{artist}" AND release:"{album}"'
    url = f'https://musicbrainz.org/ws/2/release-group/?query={urllib.parse.quote(q)}&fmt=json&limit=10'
    try:
        req = urllib.request.Request(url, headers=MB_HEADERS)
        resp = urllib.request.urlopen(req, timeout=15)
        data = json.loads(resp.read().decode('utf-8'))
        groups = data.get('release-groups', [])
        if not groups:
            return None

        # Score: penalise live/compilation/soundtrack types; prefer year match
        def score(g):
            s = 0
            pt = (g.get('primary-type') or '').lower()
            if pt in ('single', 'ep'):
                s += 2
            title = (g.get('title') or '').lower()
            if any(w in title for w in ['remaster', 'deluxe', 'anniversary', 'expanded', 'best of', 'greatest']):
                s += 5
            # reward year match
            fd = g.get('first-release-date', '') or ''
            if year and fd.startswith(str(year)):
                s -= 3
            return s

        best = sorted(groups, key=score)[0]
        return best['id']
    except Exception as e:
        print(f'    MB search error: {e}')
    return None

def fetch_from_caa(mbid):
    """Fetch front cover image bytes from Cover Art Archive."""
    url = f'https://coverartarchive.org/release-group/{mbid}/front'
    try:
        req = urllib.request.Request(url, headers={'User-Agent': MB_HEADERS['User-Agent']})
        resp = urllib.request.urlopen(req, timeout=20)
        return resp.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None   # no art in CAA for this release
        raise
    except Exception as e:
        print(f'    CAA error: {e}')
    return None

def fetch_from_itunes(artist, album):
    """Fallback: fetch art URL from iTunes Search API."""
    artist_word = re.sub(r'^the\s+', '', artist.lower(), flags=re.I).split()[0] if artist.strip() else ''
    queries = [f"{artist} {album}", artist, album]
    for q in queries:
        try:
            url = f"https://itunes.apple.com/search?term={urllib.parse.quote(q)}&entity=album&limit=20"
            req = urllib.request.Request(url, headers={
                'User-Agent': 'iTunes/12.12 (Macintosh; OS X 12.0)',
                'Accept': 'application/json'
            })
            resp = urllib.request.urlopen(req, timeout=15)
            data = json.loads(resp.read().decode('utf-8'))
            results = data.get('results', [])
            if results:
                pool = [r for r in results
                        if artist_word and artist_word in r.get('artistName','').lower()] or results
                def iscore(r):
                    return 1 if re.search(r'remaster|deluxe|anniversary|expanded',
                                          (r.get('collectionName','') or '').lower()) else 0
                best = sorted(pool, key=iscore)[0]
                art_url = best['artworkUrl100'].replace('100x100bb', '600x600bb')
                # Download the image
                img_req = urllib.request.Request(art_url, headers={'User-Agent': 'Mozilla/5.0'})
                return urllib.request.urlopen(img_req, timeout=15).read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):
                print('    iTunes rate-limited — skipping fallback')
                return None
        except Exception as e:
            print(f'    iTunes error: {e}')
        time.sleep(1)
    return None

found = skipped = failed = 0
missing = []

for i, rec in enumerate(albums):
    filename = safe_filename(rec['artist'], rec['album'])
    filepath = os.path.join(ART_DIR, filename)

    # artUrl present = we're happy with this art; skip if the file exists
    has_arturl = bool(rec.get('artUrl'))
    if has_arturl and os.path.exists(filepath):
        skipped += 1
        print(f"[{i+1}/{len(albums)}] SKIP  {rec['artist']} — {rec['album']}")
        continue

    # artUrl absent = correction requested; delete stale file so we fetch fresh
    if not has_arturl and os.path.exists(filepath):
        os.remove(filepath)
        print(f"[{i+1}/{len(albums)}] REFRESH  {rec['artist']} — {rec['album']}", end=' ', flush=True)
    else:
        print(f"[{i+1}/{len(albums)}] GET   {rec['artist']} — {rec['album']}", end=' ', flush=True)

    img_data = None

    # 1. MusicBrainz → Cover Art Archive
    mbid = mb_search(rec['artist'], rec['album'], rec.get('year'))
    time.sleep(1.1)   # MusicBrainz asks for ≤1 req/sec
    if mbid:
        img_data = fetch_from_caa(mbid)
        time.sleep(0.5)

    # 2. iTunes fallback
    if not img_data:
        img_data = fetch_from_itunes(rec['artist'], rec['album'])
        time.sleep(0.8)

    if img_data:
        with open(filepath, 'wb') as f:
            f.write(img_data)
        rec['artUrl'] = filepath
        found += 1
        print('✓')
    else:
        failed += 1
        missing.append(f"{rec['artist']} — {rec['album']}")
        print('✗ not found')

with open('albums.json', 'w') as f:
    json.dump(albums, f, indent=2, ensure_ascii=False)

print("")
print("================================================")
print(f"  Done: {found} downloaded, {skipped} skipped, {failed} failed")
print("================================================")
if missing:
    print("\nCould not find art for:")
    for m in missing:
        print(f"  • {m}")
PYEOF

echo ""
echo "Press any key to close..."
read -n 1
