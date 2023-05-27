#!/usr/bin/env bash
#
# sync a YT playlist to local mp3 files, generate a Sandisk compatible m3u file

set -eEuo pipefail

# Commandline args
ConfigFile="$HOME/.config/sandisk-sync"
DownloadFiles=1
GeneratePlaylist=1
SyncFiles=1
SyncVoice=1
UmountAfter=0

# internal vars
YTBin="$HOME/.local/bin/youtube-dl"
FfmpegBin="$(which ffmpeg)"
PlayerName="SPORT GO"
PlayerDir="/media/$USER/$PlayerName"
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

  # TODO check if we have downloaded new files before processing playlist
  # find "$SyncMusicDir" -type f -name '*.mp3' -newer "$m3u_file"


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

function ffmpeg_scale_album_art {
  local -r src="${1:?arg1 is source}"
  local -r dst="${2:?arg2 is destination}"

  # FIXME ffmpeg is not returning an error code when it fails
  if [[ ! -r "$src" ]] ; then
    echo "ERROR: $src not found" >&2
    return 1
  fi
#     -loglevel error \
  "${FfmpegBin}" \
     -y \
     -hide_banner \
     -i "$src" \
     -map 0:a:0 -map 0:v:0 \
     -filter:v scale="${AlbumArtScaleFilter}" \
     -c:v mjpeg -c:a copy \
     -id3v2_version 3 \
     "$dst"
}

function scale_album_art {
  local -r baseDir="${1:?arg1 is base dir}"
  local stamp scaled

  if [[ -z "${FfmpegBin}" ]] ; then
    echo "ffmpeg not found, skipping resizing album art" >&2
    return
  fi

  find "$baseDir" -type f -name '*.mp3'  \
    | while read -r file ; do \
        stamp="${file}.scaled"
        scaled="${file%.mp3}_scaled.mp3"
        if [[ ! -r "${stamp}" ]] ; then
          echo "scaling album art for $file"
          if ffmpeg_scale_album_art "$file" "$scaled" ; then
            if [[ -r "$scaled" ]] ; then
              mv -v "$scaled" "$file" \
                && touch "${stamp}"
            fi
          fi
        fi
      done
}

function extractAlbumArt {
  local -r mp3File="${1:?arg1 is mp3 file}"
  "${FfmpegBin}" -i "$mp3File" -an -vcodec copy "${mp3File%.mp3}.jpg"
}

function umount_after_sync {
  local -r device="$(mount | sed -ne "/$PlayerName"'/ s/^\([^ ]*\) .*$/\1/p')"

  if [[ -n "$device" && -b "$device" ]] ; then
    udisksctl unmount -b "$device"
  else
    echo "ERROR: failed to unmount $PlayerDir" >&2
  fi
}

function usage {
  cat <<EOF >&2
Usage: $(basename -- "$0") [options] [YT playlist ID]

-c file    config file ($ConfigFile)
-d         toggle download new files ($DownloadFiles)
-g         toggle generating device playlist ($GeneratePlaylist)
-h         help
-p dir     dir Sandisk player is mounted ($PlayerDir)
-r         toggle sync Voice Recordings from player ($SyncVoice)
-s         toggle sync new files to player ($SyncFiles)
-u         toggle unmount after sync ($UmountAfter)

EOF
  exit 1
}

# Main
OPTIND=1
while getopts "c:dghp:rsu" arg; do
	case $arg in
    c) ConfigFile="${OPTARG:-}";;
    d) ((DownloadFiles=(DownloadFiles==1)?0:1)) || true;;
    g) ((GeneratePlaylist=(GeneratePlaylist==1)?0:1)) || true;;
    h) usage;;
    p) PlayerDir="${OPTARG:-}";;
    r) ((SyncVoice=(SyncVoice==1)?0:1)) || true;;
    s) ((SyncFiles=(SyncFiles==1)?0:1)) || true;;
    u) ((UmountAfter=(UmountAfter==1)?0:1)) || true;;
    *) usage ;;
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
  for playlist_id in "${PlaylistIds[@]}" ; do
    download_playlist "$playlist_id"
    if [[ "$GeneratePlaylist" -eq 1 ]] ; then
      playlist_yt_m3u "${playlist_id}" "$SyncMusicDir/$playlist_id/${playlist_id}.m3u"
    fi
  done
fi
if [[ "$SyncFiles" -eq 1 ]] ; then
  sync_to_player
fi
if [[ "$SyncVoice" -eq 1 ]] ; then
  sync_voice_recordings_from_player
fi

if [[ "$UmountAfter" -eq 1 ]] ; then
  umount_after_sync
fi
