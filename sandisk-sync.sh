#!/usr/bin/env bash
#
# sync a YT playlist to local mp3 files, generate a Sandisk compatible m3u file

set -eEuo pipefail

# Commandline args
ConfigFile="$HOME/.config/sandisk-sync"
DownloadFiles=1
SyncFiles=1
SyncVoice=1

# internal vars
YTBin="$(which youtube-dl)"
FfmpegBin="$(which ffmpeg)"
PlayerDir="/media/$USER/SPORT GO"
PlayerMusicDir="${PlayerDir}/Music"
PlayerVoiceDir="${PlayerDir}/Record"
FileTemplate="%(id)s.%(ext)s"
SyncDir="$HOME/.cache/sandisk-sync"
SyncMusicDir="${SyncDir}/Music"
SyncVoiceDir="$HOME/Record"
YTCookieJar="${SyncDir}/cookiejar"
PlaylistIds=()
AlbumArtScaleFilter="400:400" # fixed size, ignore aspect ratio
#AlbumArtScaleFilter="400:-1" # fixed width, respect aspect ratio


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
    --cookies "$YTCookieJar" \
    --no-call-home \
    --yes-playlist \
    --postprocessor-args '-id3v2_version 3' \
  "$playlist_url"

  playlist_yt_m3u "${playlist_id}" "${playlist_outdir}/${playlist_id}.m3u"
  scale_album_art "${playlist_outdir}"
}

function playlist_yt_m3u {
  local -r playlist_id="${1:?arg1 is playlist id}"
  local -r m3u_file="${2:?arg2 is output m3u file}"

  local -r playlist_url="$(playlist_id_to_url "${playlist_id}")"
  local -r playlist_json="$SyncDir/${playlist_id}.json"

  if [[ -z "$(which jq)" ]] ; then
    echo "jq not found, skipping generating playlist" >&2
    return
  fi

  # convert the broken JSON to an .m3u file, with DOS line endings
  echo -n "Generating playlist ${m3u_file}..."
  (
    echo "#EXTM3U"
    echo
    $YTBin -j "$playlist_url" \
      | tee "${playlist_json}" \
      | jq -rs '["#PLAYLIST: ", .[0].playlist_title] | add'
    cat "${playlist_json}" \
     | jq -rs '.[] | [ "#EXTINF:", (.duration|tostring), " ", .uploader, " - ", .title, "\n", .id, ".mp3"] | add' 
  ) \
    | sed 's/$/\r/' \
    > "${m3u_file}.temp"
  if ! diff -q "${m3u_file}.temp" "${m3u_file}" > /dev/null ; then
    echo -n "updated..."
    mv "${m3u_file}.temp" "${m3u_file}"
  fi
  echo "done."
}

function sync_to_player {
  if [[ ! -d "$PlayerMusicDir" ]] ; then
    echo "ERROR: player music dir $PlayerMusicDir not found" >&2
    exit 1
  fi
  rsync -Paxm \
    --update \
    --modify-window 2 \
    --delete \
    --include '*.mp3' \
    --include '*.m3u' \
    -f 'hide,! */' \
    "$SyncMusicDir/" "$PlayerMusicDir/"
}

function sync_voice_recordings_from_player {
  rsync -Pax "$PlayerVoiceDir/" "$SyncVoiceDir/"
}

function scale_album_art {
  local -r baseDir="${1:?arg1 is base dir}"
  local stamp

  if [[ -z "${FfmpegBin}" ]] ; then
    echo "ffmpeg not found, skipping resizing album art" >&2
    return
  fi

  find "$baseDir" -type f -name '*.mp3'  \
    | while read file ; do \
        stamp="${file}.scaled"
        if [[ ! -r "${stamp}" ]] ; then
          echo "scaling album art for $file"
          "${FfmpegBin}" \
             -y \
             -loglevel error \
             -hide_banner \
             -i "$file" \
             -map 0:a:0 -map 0:v:0 \
             -filter:v scale="${AlbumArtScaleFilter}" \
             -c:v mjpeg -c:a copy \
             -id3v2_version 3 \
             "${file%.mp3}_scaled.mp3" \
          && mv -v "${file%.mp3}_scaled.mp3" "$file" \
          && touch "${stamp}"
        fi
      done
}

function extractAlbumArt {
  local -r mp3File="${1:?arg1 is }"
  "${FfmpegBin}" -i "$1" -an -vcodec copy "${1%.mp3}.jpg"
}

function usage {
  cat <<EOF >&2
Usage: $(basename -- "$0") [options] [YT playlist ID]

-c file    config file ($ConfigFile)
-d         toggle download new files ($DownloadFiles)
-h         help
-p dir     dir Sandisk player is mounted ($PlayerDir)
-r         toggle sync Voice Recordings from player ($SyncVoice)
-s         toggle sync new files to player ($SyncFiles)

EOF
  exit 1
}

# Main
OPTIND=1
while getopts "c:dhp:rs" arg; do
	case $arg in
    c) ConfigFile="${OPTARG:-}";;
    d) ((DownloadFiles=(DownloadFiles==1)?0:1)) || true;;
    h) usage;;
    p) PlayerDir="${OPTARG:-}";;
    r) ((SyncVoice=(SyncVoice==1)?0:1)) || true;;
    s) ((SyncFiles=(SyncFiles==1)?0:1)) || true;;
  esac
done
shift $(( OPTIND - 1 )) # remove processed options

if [[ "${#@}" -ge 1 ]] ; then
  PlaylistIds=("$@")
elif [[ -r "$ConfigFile" ]] ; then
  source "$ConfigFile"
fi
echo "${PlaylistIds[@]}"

if [[ "$DownloadFiles" -eq 1 ]] ; then
  for playlist_id in ${PlaylistIds[@]} ; do
    download_playlist "$playlist_id"
  done
fi
if [[ "$SyncFiles" -eq 1 ]] ; then
  sync_to_player
fi
if [[ "$SyncVoice" -eq 1 ]] ; then
  sync_voice_recordings_from_player
fi

