# JuiceDownloader: how it works

A desktop client for <https://juicewrldapi.com>: Windows (WPF, `src/JuiceDownloader`), Linux (Avalonia, `LinuxApp`) and
macOS (Objective-C / AppKit, `MacApp`). All three look and behave the same. Windows and Linux share the engine in
`src/JuiceDownloader/Core` (linked into `LinuxApp`); macOS has a port of it. `tests/fixtures/lyrics-match.json` holds
the lyrics cases both implementations must pass.

## What the API offers (researched November 2026)

Base `https://juicewrldapi.com/juicewrld`. No key. `robots.txt` asks for one second between crawl requests.

| Endpoint | Use here |
|---|---|
| `GET /files/list-all/` | The whole tree in one 10 MB answer: `{items:[{name,path,type,size,...}]}`, 30k items, 27k files, 408 GB. Folders report size 0; sizes are added up locally. May answer `{items:[],building:true}`: wait 3 s and ask again. |
| `GET /files/download/?path=` | The file. Honours `Range` (206 + `Content-Range`). |
| `GET /songs/?page=&page_size=` | 2,763 songs, at most 100 per page, about 13 MB in all with words. `next` links are `http://`: count pages instead of following them. `omit=lyrics,synced_lyrics` drops the words. |

A client with no usable User-Agent (Python's default) gets 403: send `JuiceDownloader/<version>`.

Songs carry `name, category (released | unreleased | unsurfaced | recording_session), era {name, description}, path,
track_titles[], file_names, lyrics, synced_lyrics`. Things that are not obvious:

- `recording_session` and `unsurfaced` songs have no `path` (one exception). Their words reach files only by matching names.
- A take is often listed twice: an `unreleased` entry with the file but no words, a `recording_session` entry with the words.
- `file_names` is free text: `File Name (1): naruto\nFile Name (2): naruto_1\nSession Title: x.ptx`, `Explicit: 06 ...`, `N/A`, or a bare name.
- `synced_lyrics` lines are `[0:07.04] words`, which is not quite LRC: `[00:07.04]words`.

## Pages

The sidebar follows the API's tree; `Catalog.SectionTable` is the map. Anything unclaimed lands on Art & Video, so nothing is hidden.

| Page | From the API |
|---|---|
| Overview | everything, with one-click section checkboxes |
| Albums | `Compilation/1. Released Discography` |
| Unreleased | `Compilation/2. Unreleased Discography` |
| Compilations | `Compilation/3. Misc. Discography` |
| Session Edits, Original Files, Studio Sessions, Instrumentals, Remixes & Edits, Snippets | the folder of that name |
| Art & Video | `Cover Arts`, `Compilation/4. Cover Art`, `Footage`, `Others`, and anything new |
| Lyrics, Missing Lyrics, Settings, About | |

## Downloads

Files keep the API's path under the chosen folder (`LocalPath`: a server path cannot climb out, and names are made legal
on all systems). Written to `name.part`, moved to `name` when complete, so a file with its real name is whole. Existing
file of the catalog's size: skipped. `.part` present: resumed by `Range`. 429/5xx/dropped connection: retried with
backoff; 4xx: failed, and the run goes on. Default eight at a time.

## Lyrics add-on

Off by default. A session's words and a finished song's are different texts: the API's session entry of "734" is 22,182 characters of takes, the released song 2,016. So the kind of recording decides first (`LyricsIndex.IsSessionFile`: the `Session Edits` and `Studio Sessions` trees or a session mark in the file's own name; the catalog's era folders called "(Sessions)" hold finished songs and do not count).

`LyricsIndex.Find(path)`: the API's own path, or the same take's other entry; then, among songs of the file's own kind only: its `file_names`, its titles with session and credit marks set aside, then with every bracket, track number, date and trailing mix word set aside, then a name in brackets ("Drinks In The Air (Stuck)"); a file joining songs ("Motions + 365") takes each one's words in turn; only then the other kind, marked `LyricsFit.OtherRecording`. A finished song takes session words only if they are short enough to be one song. A file naming a version takes that version or an unversioned song. Instrumentals get nothing.

`LyricsWriter`: `USLT` in MP3 (ID3v2.3/2.4; other frames byte for byte, atomic replace, existing words kept), plus `.lrc`/`.txt` beside the file; what cannot be tagged, including a Studio Sessions ZIP, always gets the file beside it.

**Missing Lyrics** (`Library.ScanForGapsAsync`, `SearchWebAsync`, `WebLyrics`): lists what has no words and session files with only the finished song's, and asks LRCLIB, NetEase, Genius and lyrics.ovh, ported from Music Organizer. A candidate must credit him, carry the name asked for, and have no bracket the file lacks. A session file searches "<name> session" first; a page without "session" only fills a file with no words at all and is marked as such.

Measured against the live catalog (own recording / nearest / none): Albums 320/0/0, Unreleased 1476/2/33, Compilations 54/0/0, Session Edits 152/269/12, Studio Sessions 180/329/19. 345 of the API's 523 session entries have no words at all, which is why so many session files only reach the song's.

## Download by rules

`SongRules` turns takes into songs. Default preset: the Compilation's Unreleased tree, one version of each song, no songs that came out, no hook-only ones, in one folder. The Compilation is the right source because its files are the finished MP3s; `Original Files` holds stems and mixes, `Studio Sessions` Pro Tools archives.

A song is its name without credits and take marks; `(Remix)` and `(Pt. 2)` stay separate songs. A second title merges two names only if their words agree (half the lines of the shorter). The best take goes by the API's `leak_type` (complete, then not, then open verse, then hook only), then words, then real bitrate, then length. Every group keeps its other takes, so the choice can be changed.

## Player

Any audio file (and the sound of a video) plays inside the app from its row, streamed from `/files/download/` or from the downloaded copy when there is one: `AVPlayer` on macOS, WPF `MediaPlayer` on Windows, `mpv` on Linux.

## Preview

Pictures, video and text open in a sheet before anything is downloaded (`Library.PreviewOf`), streamed from `/files/download/` or read from the downloaded copy, with the folder's other previewable files a key press away.

## Settings and cache

`settings.json` next to `cache/catalog.json` and `cache/songs.json`, in `%AppData%\JuiceDownloader`,
`~/Library/Application Support/JuiceDownloader` or `$XDG_CONFIG_HOME/JuiceDownloader`; `JUICEDOWNLOADER_SETTINGS` points
elsewhere. Keys: `language, theme, animations, backdrop, destination, parallel, confirmDownloads, refreshOnLaunch,
lyricsEnabled, lyricsEmbed, lyricsSidecar, lyricsTimedInTag, windowWidth, windowHeight, windowMaximized`.

`songs.json` does not expire. At launch, with `refreshOnLaunch` on, one small request compares the API's song count with
the kept copy and fetches the words again only when they differ; Update lyrics always fetches. A word edit that keeps the
count is not noticed until then, because the API's `last-modified` is simply the time of the request.
Default destination `~/Music/Juice WRLD`.
