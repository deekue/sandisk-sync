#!/usr/bin/env bash
#
# sync a YT playlist to local mp3 files, generate a Sandisk compatible m3u file

set -eEuo pipefail

# TODO fix album art

YTBin="youtube-dl"
PlayerDir="/media/$USER/SPORT GO"
PlayerMusicDir="${PlayerDir}/Music"
PlayerVoiceDir="${PlayerDir}/Record"
FileTemplate="%(id)s.%(ext)s"
SyncDir="$(dirname -- "$0")/sync"
SyncMusicDir="${SyncDir}/Music"
VoiceMusicDir="${VoiceDir}/Music"

# TODO pull playlist ids from a file or cmdline
PLAYLIST_IDS=(
  PLnL5AoJtd7kaJEDFJs_goCrWuRj7-hDmt
  PLwwTwi_1421AVa0oQdXkfMuonJ0ovMfqX
  )

function playlist_id_to_url {
  local -r playlist_id="${1:?arg1 is playlist id}"

  echo "https://www.youtube.com/playlist?list=${playlist_id}"
}

function download_playlist {
  local -r playlist_id="${1:?arg1 is playlist id}"

  local -r playlist_url="$(playlist_id_to_url "${playlist_id}")"
  local -r playlist_outdir="$SyncMusicDir/$playlist_id"

  mkdir -p "$playlist_outdir"

  # NOTE: Sandisk SDMX30 needs mp3 idv2.3
  $YTBin -i \
    -o "$playlist_outdir/$FileTemplate" \
    --extract-audio \
    --add-metadata \
    --embed-thumbnail \
    --audio-format mp3 \
    --audio-quality 0 \
    -f bestaudio \
    --restrict-filenames \
    --no-overwrites \
    --output-na-placeholder '_' \
    --download-archive "$playlist_outdir/archive.txt" \
    --cookies "$HOME/.cache/$(basename -- "$0").cookiejar" \
    --no-call-home \
    --yes-playlist \
    --postprocessor-args '-id3v2_version 3' \
  "$playlist_url"

  playlist_yt_m3u "${playlist_id}" "${playlist_outdir}/${playlist_id}.m3u"
}

function playlist_yt_m3u {
  local -r playlist_id="${1:?arg1 is playlist id}"
  local -r m3u_file="${2:?arg2 is output m3u file}"

  local -r playlist_url="$(playlist_id_to_url "${playlist_id}")"
  local -r playlist_json="$SyncDir/${playlist_id}.json"

  # convert the broken JSON to an .m3u file, with DOS line endings
  (
    echo "#EXTM3U"
    echo
    $YTBin -j "$playlist_url" \
      | tee "${playlist_json}" \
      | jq -rs '["#EXTPLAYLIST: ", .[0].playlist_title] | add'
    cat "${playlist_json}" \
     | jq -rs '.[] | [ "#EXTINF:", (.duration|tostring), " ", .uploader, " - ", .title, "\n", .id, ".mp3"] | add' 
  ) \
    | sed 's/$/\r/' \
    > "$m3u_file"
}

function sync_to_player {
  if [[ ! -d "$PlayerMusicDir" ]] ; then
    echo "Error: $PlayerMusicDir not found" >&2
    exit 1
  fi
  rsync -Paxm \
    --delete \
    --include '*.mp3' \
    --include '*.m3u' \
    -f 'hide,! */' \
    "$SyncMusicDir/" "$PlayerMusicDir/"
}

function sync_voice_recordings_from_player {
  rsync -Pax "$PlayerVoiceDir/" "$SyncVoiceDir/"
}

# Main
for playlist_id in ${PLAYLIST_IDS[@]} ; do
  download_playlist "$playlist_id"
done
sync_to_player
sync_voice_recordings_from_player
