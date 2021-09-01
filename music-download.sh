#!/usr/bin/env bash
#
# sync a YT playlist to local mp3 files, generate a Sandisk compatible m3u file

YTDL="youtube-dl"
SYNCDIR="/media/$USER/SPORT GO"
#OUTFILE="%(title)s-%(creator)s.%(ext)s"
#OUTFILE="%(track)s-%(artist)s.%(ext)s"
OUTFILE="%(id)s.%(ext)s"
OUTDIR="$(dirname -- "$0")/sync"

PL="${1:?arg1 is playlist URL}"

function download_playlist {
  local -r playlist_url="${1:?arg1 is playlist URL}"

  $YTDL -i \
    -o "$OUTDIR/$OUTFILE" \
    --extract-audio \
    --add-metadata \
    --embed-thumbnail \
    --audio-format mp3 \
    --audio-quality 0 \
    -f bestaudio \
    --restrict-filenames \
    --no-overwrites \
    --output-na-placeholder '_' \
    --download-archive "$OUTDIR/archive.txt" \
    --cookies "$HOME/.cache/$(basename -- "$0").cookiejar" \
    --write-info-json \
    --no-call-home \
    --yes-playlist \
  "$playlist_url"
}

function generate_m3u {
  local fields index name
  local -a playlist
  local -r m3u_file="$OUTDIR/playlist.m3u"

  for file in $OUTDIR/*.info.json ; do
    fields="$(jq -r '[(.playlist_index|tostring), ":", ._filename] | add' "$file")"
    index="${fields%%:*}"
    name="${fields##*:}"
    name="${name%.*}.mp3"
    playlist[$index]="${name#$OUTDIR/}"
  done
  : > "$m3u_file"
  for index in ${!playlist[@]} ; do
    echo "${playlist[$index]}" >> "$m3u_file"
  done
}

function playlist_yt_m3u {
  local -r playlist_url="${1:?arg1 is playlist URL}"
  local -r m3u_file="${2:?arg2 is output m3u file}"

  $YTDL -j --flat-playlist "$playlist_url" \
    | jq -rs '.[] | [ .id, ".mp3"] | add' \
    | sed 's/$/\r/' \
    > "$m3u_file"
}

function sync_to_player {
  cd "$OUTDIR"
  if [[ ! -d "$SYNCDIR/Music" ]] ; then
    echo "Error: $SYNCDIR/Music not found" >&2
    exit 1
  fi
  # TODO sync a playlist to its own dir
  rsync -cx --progress -- *.mp3 *.m3u "$SYNCDIR/Music/YouTube_Music/"
  cd -
}

function sync_voice_recordings_from_player {
  rsync -Pax "$SYNCDIR/Record/" "$OUTDIR/voice/"
}

download_playlist "$PL"
playlist_yt_m3u "$PL" "$OUTDIR/YouTube_Music.m3u"
sync_to_player
sync_voice_recordings_from_player
