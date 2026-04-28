#!/usr/bin/env python3

# ===================================================================================
# Purpose:     Create and maintain hardlinks for female performers from Whisparr
#              into /mnt/Share/Plex/Adult/Actresses/<Performer Name>/
#              Removes stale actress hardlinks that are no longer expected.
# Author:      Cory Funk 2026
# ===================================================================================

import os
import re
import sys
import hashlib
from pathlib import Path

import requests

# ===================================================================================
# Configuration
# ===================================================================================
WHISPARR_URL = "http://127.0.0.1:56969/api/v3"
API_KEY = "f79e40f7647d43b6b3bf6138b72fb0f3"

MEDIA_ROOT = Path("/mnt/Share/Plex/Adult").resolve()
ACTRESS_ROOT = MEDIA_ROOT / "Actresses"

TIMEOUT = 120

HEADERS = {
    "X-Api-Key": API_KEY
}

VIDEO_EXTENSIONS = {
    ".mp4", ".mkv", ".avi", ".mov", ".wmv", ".m4v", ".mpg", ".mpeg", ".ts", ".webm"
}

# ===================================================================================
# Helper Functions
# ===================================================================================
def log(message):
    print(message, flush=True)

def sanitize_name(name):
    if not name:
        return "Unknown"

    name = re.sub(r'[<>:"/\\|?*]', "-", name)
    name = re.sub(r"\s+", " ", name).strip()
    name = name.rstrip(".")
    return name or "Unknown"

def api_get(endpoint, params=None):
    url = f"{WHISPARR_URL.rstrip('/')}/{endpoint.lstrip('/')}"
    response = requests.get(url, headers=HEADERS, params=params, timeout=TIMEOUT)
    response.raise_for_status()
    return response.json()

def is_video_file(path_obj):
    return path_obj.suffix.lower() in VIDEO_EXTENSIONS

def is_within_media_root(file_path):
    try:
        resolved_path = Path(file_path).resolve()
        resolved_path.relative_to(MEDIA_ROOT)
        return True
    except Exception:
        return False

def build_collision_safe_name(source_path):
    suffix = source_path.suffix
    stem = source_path.stem
    short_hash = hashlib.sha1(str(source_path).encode("utf-8")).hexdigest()[:8]
    return f"{stem} [{short_hash}]{suffix}"

def same_file_by_stat(path_a, path_b):
    try:
        stat_a = os.stat(path_a)
        stat_b = os.stat(path_b)
        return (
            stat_a.st_dev == stat_b.st_dev and
            stat_a.st_ino == stat_b.st_ino
        )
    except Exception:
        return False

def ensure_hardlink(src, dest):
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)

        if dest.is_symlink():
            dest.unlink()

        if dest.exists():
            if same_file_by_stat(src, dest):
                return "skipped"

            collision_dest = dest.parent / build_collision_safe_name(src)

            if collision_dest.exists():
                if same_file_by_stat(src, collision_dest):
                    return "skipped"
                return "skipped"

            os.link(src, collision_dest)
            return "created"

        os.link(src, dest)
        return "created"

    except Exception as e:
        log(f"ERROR: Failed to create hardlink: {dest} -> {src} | {e}")
        return "error"

def remove_old_symlinks(root_path):
    removed = 0

    if not root_path.exists():
        return removed

    for path in root_path.rglob("*"):
        try:
            if path.is_symlink():
                path.unlink()
                removed += 1
                log(f"Removed old symlink: {path}")
        except Exception as e:
            log(f"WARNING: Could not remove symlink {path}: {e}")

    return removed

def remove_stale_actress_files(root_path, expected_paths):
    removed = 0
    skipped_non_files = 0

    if not root_path.exists():
        return removed, skipped_non_files

    for path in root_path.rglob("*"):
        try:
            if not path.is_file():
                continue

            if path not in expected_paths:
                path.unlink()
                removed += 1
                log(f"Removed stale actress file: {path}")
        except IsADirectoryError:
            skipped_non_files += 1
        except Exception as e:
            log(f"WARNING: Could not remove stale file {path}: {e}")

    return removed, skipped_non_files

def cleanup_empty_dirs(root_path):
    removed = 0

    if not root_path.exists():
        return removed

    for path in sorted(root_path.rglob("*"), reverse=True):
        try:
            if path.is_dir() and not any(path.iterdir()):
                path.rmdir()
                removed += 1
                log(f"Removed empty directory: {path}")
        except Exception:
            pass

    return removed

def is_female_performer(performer):
    gender = performer.get("gender")

    if isinstance(gender, str):
        return gender.strip().lower() == "female"

    return False

def get_performer_display_name(performer):
    return sanitize_name(
        performer.get("performerName")
        or performer.get("name")
        or "Unknown"
    )

def build_female_performer_lookup(performers):
    female_lookup = {}

    for performer in performers:
        if not is_female_performer(performer):
            continue

        foreign_id = performer.get("foreignId")
        if not foreign_id:
            continue

        female_lookup[foreign_id] = get_performer_display_name(performer)

    return female_lookup

def get_matching_female_names(movie, female_lookup):
    matched_names = []

    performer_foreign_ids = movie.get("performerForeignIds") or []

    for foreign_id in performer_foreign_ids:
        if foreign_id in female_lookup:
            matched_names.append(female_lookup[foreign_id])

    seen = set()
    deduped = []

    for name in matched_names:
        if name not in seen:
            seen.add(name)
            deduped.append(name)

    return deduped

# ===================================================================================
# Main Logic
# ===================================================================================
def main():
    if not API_KEY or API_KEY == "YOUR_API_KEY_HERE":
        log("ERROR: Please set your Whisparr API key in the script.")
        return 1

    if not MEDIA_ROOT.exists():
        log(f"ERROR: MEDIA_ROOT does not exist: {MEDIA_ROOT}")
        return 1

    ACTRESS_ROOT.mkdir(parents=True, exist_ok=True)

    try:
        performers = api_get("performer")
    except Exception as e:
        log(f"ERROR: Unable to retrieve performers from Whisparr: {e}")
        return 1

    female_lookup = build_female_performer_lookup(performers)

    if not female_lookup:
        log("WARNING: No female performers were found in the performer API.")
        return 0

    try:
        movie_files = api_get("moviefile")
    except Exception as e:
        log(f"ERROR: Unable to retrieve movie files from Whisparr: {e}")
        return 1

    movie_cache = {}
    expected_destinations = set()

    total_performers_checked = len(performers)
    total_female_performers = len(female_lookup)
    total_movie_files_checked = 0
    total_movie_files_in_root = 0
    total_movie_files_missing = 0
    total_movie_files_non_video = 0
    total_movie_files_outside_root = 0
    total_movies_fetched = 0
    total_movies_failed = 0
    total_movies_with_female_performers = 0
    total_links_created = 0
    total_links_skipped = 0
    total_links_errors = 0

    old_symlinks_removed = remove_old_symlinks(ACTRESS_ROOT)

    for movie_file in movie_files:
        total_movie_files_checked += 1

        file_path = movie_file.get("path")
        movie_id = movie_file.get("movieId")

        if not file_path or not movie_id:
            continue

        source_path = Path(file_path)

        if not source_path.exists():
            total_movie_files_missing += 1
            log(f"WARNING: File missing: {source_path}")
            continue

        if not is_within_media_root(source_path):
            total_movie_files_outside_root += 1
            continue

        total_movie_files_in_root += 1

        if not is_video_file(source_path):
            total_movie_files_non_video += 1
            continue

        if movie_id not in movie_cache:
            try:
                movie_cache[movie_id] = api_get(f"movie/{movie_id}")
                total_movies_fetched += 1
            except Exception as e:
                total_movies_failed += 1
                log(f"WARNING: Could not retrieve movie ID {movie_id}: {e}")
                movie_cache[movie_id] = None
                continue

        movie = movie_cache[movie_id]
        if not movie:
            continue

        female_names = get_matching_female_names(movie, female_lookup)
        if not female_names:
            continue

        total_movies_with_female_performers += 1

        for performer_name in female_names:
            performer_dir = ACTRESS_ROOT / performer_name
            link_path = performer_dir / source_path.name
            expected_destinations.add(link_path)

            result = ensure_hardlink(source_path, link_path)

            if result == "created":
                total_links_created += 1
                log(f"Hardlinked: {link_path} -> {source_path}")
            elif result == "skipped":
                total_links_skipped += 1
            else:
                total_links_errors += 1

    stale_removed, stale_non_files_skipped = remove_stale_actress_files(
        ACTRESS_ROOT,
        expected_destinations
    )
    empty_dirs_removed = cleanup_empty_dirs(ACTRESS_ROOT)

    log("")
    log("===================================================================================")
    log("Completed")
    log("===================================================================================")
    log(f"Performers checked:              {total_performers_checked}")
    log(f"Female performers found:         {total_female_performers}")
    log(f"Movie files checked:             {total_movie_files_checked}")
    log(f"Movie files in media root:       {total_movie_files_in_root}")
    log(f"Movie files missing:             {total_movie_files_missing}")
    log(f"Movie files outside root:        {total_movie_files_outside_root}")
    log(f"Non-video files skipped:         {total_movie_files_non_video}")
    log(f"Movies fetched:                  {total_movies_fetched}")
    log(f"Movies failed:                   {total_movies_failed}")
    log(f"Movies with female performers:   {total_movies_with_female_performers}")
    log(f"Hardlinks created:               {total_links_created}")
    log(f"Hardlinks skipped:               {total_links_skipped}")
    log(f"Hardlink errors:                 {total_links_errors}")
    log(f"Old symlinks removed:            {old_symlinks_removed}")
    log(f"Stale actress files removed:     {stale_removed}")
    log(f"Non-file stale entries skipped:  {stale_non_files_skipped}")
    log(f"Empty directories removed:       {empty_dirs_removed}")
    log(f"Media root:                      {MEDIA_ROOT}")
    log(f"Actress root:                    {ACTRESS_ROOT}")

    return 0

if __name__ == "__main__":
    sys.exit(main())
