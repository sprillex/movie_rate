import os
import sqlite3
import urllib.parse
import requests
import time
import yt_dlp
from plexapi.server import PlexServer
from dotenv import load_dotenv

load_dotenv()

PLEX_URL = os.getenv('PLEX_URL').rstrip('/')
PLEX_TOKEN = os.getenv('PLEX_TOKEN')
TMDB_API_KEY = os.getenv('TMDB_API_KEY')
DB_FILE = 'movies.db'

# Add your favorite trailer channels here using their exact YouTube @handle
WHITELISTED_HANDLES = [
    "@GrindhouseMovieTrailers",
]

def get_tmdb_trailer(title, year):
    """Queries TMDB for the exact official YouTube trailer link."""
    if not TMDB_API_KEY:
        return None
        
    search_url = "https://api.themoviedb.org/3/search/movie"
    search_params = {
        "api_key": TMDB_API_KEY,
        "query": title,
        "primary_release_year": year
    }
    
    try:
        search_resp = requests.get(search_url, params=search_params, timeout=10)
        
        if search_resp.status_code == 429:
            time.sleep(2)
            return None
            
        results = search_resp.json().get('results', [])
        
        if not results:
            return None
            
        movie_id = results[0]['id']
        
        video_url = f"https://api.themoviedb.org/3/movie/{movie_id}/videos"
        video_resp = requests.get(video_url, params={"api_key": TMDB_API_KEY}, timeout=10)
        
        if video_resp.status_code == 429:
            time.sleep(2)
            return None
            
        trailers = [v for v in video_resp.json().get('results', []) if v.get('site') == 'YouTube' and v.get('type') == 'Trailer']
        
        if trailers:
            return f"https://www.youtube.com/watch?v={trailers[0]['key']}"
            
    except Exception as e:
        print(f"  [!] TMDB API error for {title}: {e}")
        
    return None

def get_ytdlp_trailer(title, year):
    """Falls back to scraping YouTube, prioritizing whitelisted channels."""
    print(f"  [-] TMDB missed. Searching YouTube for: '{title} ({year})'...")
    ydl_opts = {
        'quiet': True,
        'extract_flat': True, 
    }
    
    query = f"ytsearch10:{title} {year} trailer"
    
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        try:
            info = ydl.extract_info(query, download=False)
            
            if 'entries' in info and info['entries']:
                for entry in info['entries']:
                    uploader_id = entry.get('uploader_id')
                    if uploader_id in WHITELISTED_HANDLES:
                        print(f"    [SUCCESS] Whitelisted Match: {uploader_id}")
                        return entry.get('url')
                
                top_result = info['entries'][0]
                print(f"    [INFO] No whitelist match. Using top result from: {top_result.get('uploader_id')}")
                return top_result.get('url')
                
        except Exception as e:
            print(f"    [!] yt-dlp error: {e}")
            
    return None

def sync_plex_to_db():
    print("Connecting to Plex Server...")
    plex = PlexServer(PLEX_URL, PLEX_TOKEN)
    movies_section = plex.library.section('Movies')
    machine_id = plex.machineIdentifier
    
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    added_count = 0
    updated_count = 0

    print("Scanning Plex and querying TMDB/YouTube...")
    for video in movies_section.search():
        encoded_key = urllib.parse.quote(video.key, safe='')
        direct_url = f"{PLEX_URL}/web/index.html#!/server/{machine_id}/details?key={encoded_key}"

        # Try to find by plex_id first
        cursor.execute("SELECT id, tmdb_trailer_url, user_edited FROM movies WHERE plex_id = ?", (video.key,))
        row = cursor.fetchone()
        
        # Fallback to title and year if not found by plex_id
        if not row:
            cursor.execute("SELECT id, tmdb_trailer_url, user_edited FROM movies WHERE title = ? AND year = ?", (video.title, video.year))
            row = cursor.fetchone()

        trailer_url = row[1] if row else None

        if not trailer_url:
            trailer_url = get_tmdb_trailer(video.title, video.year)
            if not trailer_url:
                trailer_url = get_ytdlp_trailer(video.title, video.year)

        if row:
            user_edited = row[2]
            if user_edited == 1:
                cursor.execute('''
                    UPDATE movies
                    SET plex_id = ?, plex_url = ?, tmdb_trailer_url = ?
                    WHERE id = ?
                ''', (video.key, direct_url, trailer_url, row[0]))
            else:
                try:
                    cursor.execute('''
                        UPDATE movies
                        SET title = ?, year = ?, summary = ?, plex_id = ?, plex_url = ?, tmdb_trailer_url = ?
                        WHERE id = ?
                    ''', (video.title, video.year, video.summary, video.key, direct_url, trailer_url, row[0]))
                except sqlite3.IntegrityError:
                    cursor.execute('''
                        UPDATE movies
                        SET title = ?, year = ?, summary = ?, plex_id = ?, plex_url = ?, tmdb_trailer_url = ?
                        WHERE id = ?
                    ''', (f"{video.title} [Duplicate {row[0]}]", video.year, video.summary, video.key, direct_url, trailer_url, row[0]))
            updated_count += 1
        else:
            try:
                cursor.execute('''
                    INSERT INTO movies (title, year, summary, plex_url, tmdb_trailer_url, elo, matchups, status, watchlist, plex_id)
                    VALUES (?, ?, ?, ?, ?, 1000, 0, 'active', 0, ?)
                ''', (video.title, video.year, video.summary, direct_url, trailer_url, video.key))
            except sqlite3.IntegrityError:
                 # Need an ID for the duplicate string, so insert, get id, and update
                 cursor.execute('''
                    INSERT INTO movies (title, year, summary, plex_url, tmdb_trailer_url, elo, matchups, status, watchlist, plex_id)
                    VALUES (?, ?, ?, ?, ?, 1000, 0, 'active', 0, ?)
                ''', (f"{video.title} [Duplicate Pending]", video.year, video.summary, direct_url, trailer_url, video.key))
                 new_id = cursor.lastrowid
                 cursor.execute("UPDATE movies SET title = ? WHERE id = ?", (f"{video.title} [Duplicate {new_id}]", new_id))
            added_count += 1
            
    conn.commit()
    conn.close()
    print(f"Sync complete! Added {added_count} new movies and updated {updated_count} existing entries.")

if __name__ == '__main__':
    sync_plex_to_db()
