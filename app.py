import os
import sqlite3
import random
import yt_dlp
from flask import Flask, render_template, request, redirect, url_for, jsonify
from plexapi.server import PlexServer
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)

K_FACTOR = 32
DB_FILE = 'movies.db'

def get_db_connection():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row 
    return conn

def calculate_elo(rating_a, rating_b, actual_a):
    expected_a = 1 / (1 + 10 ** ((rating_b - rating_a) / 400))
    expected_b = 1 / (1 + 10 ** ((rating_a - rating_b) / 400))
    new_a = rating_a + K_FACTOR * (actual_a - expected_a)
    new_b = rating_b + K_FACTOR * ((1 - actual_a) - expected_b)
    return round(new_a, 2), round(new_b, 2)

@app.route('/')
def index():
    id_a = request.args.get('id_a')
    id_b = request.args.get('id_b')
    conn = get_db_connection()
    
    try:
        if id_a and id_b and id_a != "None" and id_b != "None":
            movie_a = conn.execute("SELECT * FROM movies WHERE id = ?", (id_a,)).fetchone()
            movie_b = conn.execute("SELECT * FROM movies WHERE id = ?", (id_b,)).fetchone()
        else:
            active = conn.execute("SELECT * FROM movies WHERE status = 'active'").fetchall()
            if len(active) < 2:
                conn.close()
                return "Not enough active movies.", 400
            movie_a, movie_b = random.sample(active, 2)
    except Exception:
        active = conn.execute("SELECT * FROM movies WHERE status = 'active'").fetchall()
        movie_a, movie_b = random.sample(active, 2)
        
    conn.close()
    return render_template('index.html', movie_a=movie_a, movie_b=movie_b)

@app.route('/vote', methods=['POST'])
def vote():
    action = request.form.get('action')
    id_a, id_b = request.form.get('id_a'), request.form.get('id_b')
    
    if not action:
        return redirect(url_for('index'))

    conn = get_db_connection()
    if request.form.get('watchlist_a'): conn.execute("UPDATE movies SET watchlist = 1 WHERE id = ?", (id_a,))
    if request.form.get('watchlist_b'): conn.execute("UPDATE movies SET watchlist = 1 WHERE id = ?", (id_b,))
    
    if action in ['A_wins', 'B_wins']:
        a = conn.execute("SELECT elo FROM movies WHERE id = ?", (id_a,)).fetchone()
        b = conn.execute("SELECT elo FROM movies WHERE id = ?", (id_b,)).fetchone()
        new_a, new_b = calculate_elo(a['elo'], b['elo'], 1 if action == 'A_wins' else 0)
        conn.execute("UPDATE movies SET elo = ?, matchups = matchups + 1 WHERE id = ?", (new_a, id_a))
        conn.execute("UPDATE movies SET elo = ?, matchups = matchups + 1 WHERE id = ?", (new_b, id_b))
    elif action.startswith('set_aside'):
        target = id_a if '_a' in action else id_b
        conn.execute("UPDATE movies SET status = 'review' WHERE id = ?", (target,))
    
    conn.commit()
    conn.close()
    return redirect(url_for('index'))

@app.route('/watchlist')
def watchlist():
    sort_by = request.args.get('sort', 'title')
    conn = get_db_connection()
    if sort_by == 'rank':
        movies = conn.execute("SELECT * FROM movies WHERE watchlist = 1 ORDER BY elo DESC, title ASC").fetchall()
    else:
        movies = conn.execute("SELECT * FROM movies WHERE watchlist = 1 ORDER BY title ASC").fetchall()
    conn.close()
    return render_template('watchlist.html', movies=movies, current_sort=sort_by)

@app.route('/watchlist_remove', methods=['POST'])
def watchlist_remove():
    conn = get_db_connection()
    conn.execute("UPDATE movies SET watchlist = 0 WHERE id = ?", (request.form.get('id'),))
    conn.commit()
    conn.close()
    return redirect(url_for('watchlist'))

@app.route('/edit_movie/<int:movie_id>')
def edit_movie(movie_id):
    other_id = request.args.get('other_id')
    conn = get_db_connection()
    movie = conn.execute("SELECT * FROM movies WHERE id = ?", (movie_id,)).fetchone()
    conn.close()
    return render_template('edit_movie.html', movie=movie, other_id=other_id)

@app.route('/update_movie', methods=['POST'])
def update_movie():
    mid, oid = request.form.get('movie_id'), request.form.get('other_id')
    title, year, summary = request.form.get('title'), request.form.get('year'), request.form.get('summary')
    conn = get_db_connection()
    try:
        conn.execute("UPDATE movies SET title=?, year=?, summary=? WHERE id=?",
                     (title, year, summary, mid))
    except sqlite3.IntegrityError:
        conn.execute("UPDATE movies SET title = title || ' [Duplicate ' || id || ']' WHERE title=? AND year=? AND id!=?", (title, year, mid))
        conn.execute("UPDATE movies SET title=?, year=?, summary=? WHERE id=?",
                     (title, year, summary, mid))
    conn.commit()
    conn.close()
    return redirect(url_for('index', id_a=mid, id_b=oid) if oid and oid != "None" else url_for('index'))

@app.route('/sync_check/<int:movie_id>')
def sync_check(movie_id):
    conn = get_db_connection()
    movie = conn.execute("SELECT * FROM movies WHERE id = ?", (movie_id,)).fetchone()
    conn.close()
    if not movie or not movie['plex_id']:
        return jsonify({"status": "Error", "details": "No Plex ID linked."})
    try:
        plex = PlexServer(os.getenv('PLEX_URL'), os.getenv('PLEX_TOKEN'))
        p_movie = plex.fetchItem(movie['plex_id'])
        diffs = []
        if (p_movie.title or "").strip() != (movie['title'] or "").strip(): diffs.append("Title")
        if str(p_movie.year or "") != str(movie['year'] or ""): diffs.append("Year")
        return jsonify({"status": "Mismatch" if diffs else "Match", "details": ", ".join(diffs) if diffs else "In Sync"})
    except Exception as e:
        return jsonify({"status": "Error", "details": str(e)})

@app.route('/apply_plex_sync/<int:movie_id>', methods=['POST'])
def apply_plex_sync(movie_id):
    other_id = request.form.get('other_id')
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT plex_id FROM movies WHERE id = ?", (movie_id,)).fetchone()
        if row and row['plex_id']:
            plex = PlexServer(os.getenv('PLEX_URL'), os.getenv('PLEX_TOKEN'))
            p_movie = plex.fetchItem(row['plex_id'])
            try:
                conn.execute("UPDATE movies SET title=?, year=?, summary=? WHERE id=?",
                             (p_movie.title, p_movie.year, p_movie.summary, movie_id))
            except sqlite3.IntegrityError:
                conn.execute("UPDATE movies SET title = title || ' [Duplicate ' || id || ']' WHERE title=? AND year=? AND id!=?", (p_movie.title, p_movie.year, movie_id))
                conn.execute("UPDATE movies SET title=?, year=?, summary=? WHERE id=?",
                             (p_movie.title, p_movie.year, p_movie.summary, movie_id))
            conn.commit()
    except Exception as e:
        print(f"Apply Sync Error: {e}")
    finally:
        conn.close()
    
    if other_id and other_id != "None" and str(other_id).isdigit():
        return redirect(url_for('index', id_a=movie_id, id_b=other_id))
    return redirect(url_for('index'))

@app.route('/find_trailer/<int:movie_id>')
def find_trailer(movie_id):
    other_id = request.args.get('other_id')
    conn = get_db_connection()
    movie = conn.execute("SELECT * FROM movies WHERE id = ?", (movie_id,)).fetchone()
    
    ydl_opts = {
        'quiet': True, 
        'extract_flat': True,
        'user_agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }
    
    query = f"ytsearch10:{movie['title']} {movie['year']} trailer"
    results = []
    
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(query, download=False)
            if 'entries' in info:
                for entry in info['entries']:
                    duration = entry.get('duration')
                    if duration and duration <= 360:
                        mins, secs = divmod(int(duration), 60)
                        entry['formatted_duration'] = f"{mins}:{secs:02d}"
                        handle = entry.get('uploader_id')
                        score_row = conn.execute("SELECT score FROM channel_scores WHERE handle = ?", (handle,)).fetchone()
                        entry['score'] = score_row['score'] if score_row else 1000
                        results.append(entry)
                    if len(results) >= 5: break
    except Exception as e:
        print(f"Trailer Search Error: {e}")
    finally:
        conn.close()

    results.sort(key=lambda x: x.get('score', 1000), reverse=True)
    return render_template('trailer_search.html', movie=movie, results=results, other_id=other_id)

@app.route('/set_trailer', methods=['POST'])
def set_trailer():
    mid, oid = request.form.get('movie_id'), request.form.get('other_id')
    sel_url, sel_chan = request.form.get('selected_url'), request.form.get('selected_channel')
    all_chans = request.form.getlist('all_channels')
    conn = get_db_connection()
    conn.execute("UPDATE movies SET tmdb_trailer_url = ? WHERE id = ?", (sel_url, mid))
    for chan in all_chans:
        if not chan: continue
        conn.execute("INSERT OR IGNORE INTO channel_scores (handle, score) VALUES (?, 1000)", (chan,))
        adj = 10 if chan == sel_chan else -2
        conn.execute("UPDATE channel_scores SET score = score + ? WHERE handle = ?", (adj, chan))
    conn.commit()
    conn.close()
    return redirect(url_for('index', id_a=mid, id_b=oid) if oid and oid != "None" else url_for('index'))

@app.route('/clear_trailer', methods=['POST'])
def clear_trailer():
    mid, oid = request.form.get('movie_id'), request.form.get('other_id')
    conn = get_db_connection()
    conn.execute("UPDATE movies SET tmdb_trailer_url = NULL WHERE id = ?", (mid,))
    conn.commit()
    conn.close()
    return redirect(url_for('index', id_a=mid, id_b=oid) if oid and oid != "None" else url_for('index'))


@app.route('/rankings')
def rankings():
    page = max(1, request.args.get('page', 1, type=int))
    per_page = 50
    offset = (page - 1) * per_page

    conn = get_db_connection()
    total_movies = conn.execute("SELECT COUNT(*) FROM movies").fetchone()[0]
    movies = conn.execute("SELECT * FROM movies ORDER BY elo DESC LIMIT ? OFFSET ?", (per_page, offset)).fetchall()
    conn.close()

    total_pages = (total_movies + per_page - 1) // per_page

    return render_template('rankings.html', movies=movies, page=page, total_pages=total_pages)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.getenv("FLASK_PORT", 5000)))
