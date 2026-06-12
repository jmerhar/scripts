#!/usr/bin/env bash
#
# Reports on subtitle coverage for media files in a directory tree.
#
# For every media file it finds, the script detects subtitles from two sources:
# embedded tracks inside the container (via ffprobe) and external "sidecar"
# subtitle files sharing the media file's base name. It then prints a summary of
# how many files have subtitles and in which languages, broken down by source.
#
# Optionally it can list every media file with its subtitles, or just the files
# that are missing subtitles entirely (or missing a specific language).
#
# Usage:
#   ./subtitle-report.sh [OPTIONS] [DIRECTORY]

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../lib/common.sh"
# @include ../lib/common.sh

# --- Global State (option flags) ---
_no_color=false
_no_embedded=false
_no_sidecars=false
_do_list=false
_do_missing=false
_lang=""           # Raw --lang argument, if any.
_lang_norm=""      # Normalized form of _lang, used for matching.
_target_dir="."

# Media and subtitle extensions. Defaults below may be overridden by a config
# file (MEDIA_EXTS / SUBTITLE_EXTS arrays); see load_config in common.sh.
_media_exts=(mkv mp4 m4v avi mov wmv mpg mpeg ts m2ts webm flv ogv 3gp divx vob)
_subtitle_exts=(srt ass ssa sub idx vtt sup)

# Sidecar filename tokens that describe a subtitle's role rather than its
# language (e.g. "Movie.en.forced.srt"). Skipped during language detection.
_sidecar_flags=(forced sdh cc hi default foreign full)

# Per-media-file results, as parallel indexed arrays (indexed arrays are used
# rather than a delimited string so filenames containing spaces are safe).
# _media_subs[i] is a space-separated list of "lang:source" tokens, where source
# is "emb" or "side"; an empty string means the file has no subtitles.
_media_paths=()
_media_subs=()

# Aggregate counters, keyed by normalized language.
declare -A _lang_files=()   # files having at least one subtitle in the language
declare -A _lang_emb=()     # files with an embedded subtitle in the language
declare -A _lang_side=()    # files with a sidecar subtitle in the language

# Canonical-language lookup, populated once by init_lang_map() before scanning.
# Maps any known ISO 639-1/639-2 code or English language name (lowercased) to a
# single canonical token (the ISO 639-1 code) so equivalent forms compare equal.
declare -A _lang_canon=()
_lang_map_ready=false

# Headline counters.
_total=0
_with_subs=0
_emb_only=0
_side_only=0
_both=0

# --- Color Variables (set by setup_colors) ---
_C_CYAN=""
_C_GREEN=""
_C_BRIGHT_GREEN=""
_C_YELLOW=""
_C_MAGENTA=""
_C_WHITE=""
_C_DIM=""
_C_BOLD=""
_C_RESET=""

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [DIRECTORY]

Report on subtitle coverage for media files in a directory tree.

Options:
  -l, --list           List every media file and the subtitles it has.
  -m, --missing        List media files that have no subtitles at all.
  -g, --lang LANG      Scope the report to one language (e.g. en, eng, english).
                       With --missing: list files missing LANG specifically.
                       With --list:    annotate each file's LANG status.
                       Alone:          implies a "missing LANG" listing.
      --no-embedded    Skip embedded-track inspection (sidecars only; fast).
      --no-sidecars    Skip sidecar files (embedded tracks only). Useful for
                       finding media that lacks an embedded subtitle track,
                       regardless of any sidecar files alongside it.
  -C, --no-color       Disable colored output.
  -h, --help           Show this help message.

The summary is always printed; --list / --missing add a detailed section.
--list and --missing are mutually exclusive, as are --no-embedded and
--no-sidecars.
If no directory is given, the current directory is used.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _no_color, _no_embedded, _no_sidecars, _do_list, _do_missing, _lang,
#   _target_dir
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--list)
        _do_list=true
        shift
        ;;
      -m|--missing)
        _do_missing=true
        shift
        ;;
      -g|--lang)
        if [[ $# -lt 2 ]]; then
          log_error "Option '$1' requires a language argument."
          exit 1
        fi
        _lang="$2"
        shift 2
        ;;
      --no-embedded)
        _no_embedded=true
        shift
        ;;
      --no-sidecars)
        _no_sidecars=true
        shift
        ;;
      -C|--no-color)
        _no_color=true
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        log_error "Unknown option '$1'. Use --help for usage."
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ "${_do_list}" == true && "${_do_missing}" == true ]]; then
    log_error "--list and --missing are mutually exclusive."
    exit 1
  fi

  if [[ "${_no_embedded}" == true && "${_no_sidecars}" == true ]]; then
    log_error "--no-embedded and --no-sidecars cannot be combined; nothing would be analysed."
    exit 1
  fi

  if [[ ${#positional[@]} -gt 1 ]]; then
    log_error "Expected at most one directory argument, got ${#positional[@]}."
    exit 1
  fi

  if [[ ${#positional[@]} -eq 1 ]]; then
    _target_dir="${positional[0]}"
    if [[ ! -d "${_target_dir}" ]]; then
      log_error "'${_target_dir}' is not a directory."
      exit 1
    fi
  fi
}

########################################
# Configures color variables based on terminal capability and user preference.
# Globals:
#   _no_color, _C_CYAN, _C_GREEN, _C_BRIGHT_GREEN, _C_YELLOW, _C_MAGENTA,
#   _C_WHITE, _C_DIM, _C_BOLD, _C_RESET
# Arguments:
#   None
########################################
setup_colors() {
  if [[ "${_no_color}" == true ]]; then
    return
  fi
  if [[ ! -t 1 ]]; then
    return
  fi
  _C_CYAN=$'\033[36m'
  _C_GREEN=$'\033[32m'
  _C_BRIGHT_GREEN=$'\033[92m'
  _C_YELLOW=$'\033[33m'
  _C_MAGENTA=$'\033[35m'
  _C_WHITE=$'\033[97m'
  _C_DIM=$'\033[2m'
  _C_BOLD=$'\033[1m'
  _C_RESET=$'\033[0m'
}

########################################
# Applies optional MEDIA_EXTS / SUBTITLE_EXTS overrides from a loaded config
# file. Each is honored only when declared as a non-empty array, so a config
# that sets neither (or none at all) leaves the built-in defaults intact.
# Globals:
#   MEDIA_EXTS, SUBTITLE_EXTS, _media_exts, _subtitle_exts
# Arguments:
#   None
########################################
apply_config() {
  if declare -p MEDIA_EXTS &>/dev/null && (( ${#MEDIA_EXTS[@]} > 0 )); then
    _media_exts=("${MEDIA_EXTS[@]}")
  fi
  if declare -p SUBTITLE_EXTS &>/dev/null && (( ${#SUBTITLE_EXTS[@]} > 0 )); then
    _subtitle_exts=("${SUBTITLE_EXTS[@]}")
  fi
}

########################################
# Populates the canonical-language lookup table (_lang_canon) from the embedded
# ISO 639 dataset. Every alpha-2 code, both alpha-3 forms (bibliographic and
# terminologic), and the registry's English name(s) map to the alpha-2 code.
# Guarded by _lang_map_ready so it builds at most once; call it directly in the
# parent shell before scanning so command-substitution subshells (which inherit
# the populated array) only ever do lookups, never rebuilds.
#
# The dataset is generated from the Library of Congress ISO 639-2 registry
# (https://www.loc.gov/standards/iso639-2/), limited to languages that have an
# alpha-2 code; columns are "alpha2|alpha3-bib|alpha3-term|name[,name...]".
# Name forms that would be ambiguous (map to more than one language) are omitted.
# Globals:
#   _lang_canon, _lang_map_ready
# Arguments:
#   None
########################################
init_lang_map() {
  [[ "${_lang_map_ready}" == true ]] && return
  _lang_map_ready=true

  local a2 b t names key
  local -a name_list
  while IFS='|' read -r a2 b t names; do
    [[ -n "${a2}" ]] || continue
    _lang_canon["${a2}"]="${a2}"
    [[ -n "${b}" ]] && _lang_canon["${b}"]="${a2}"
    [[ -n "${t}" ]] && _lang_canon["${t}"]="${a2}"
    if [[ -n "${names}" ]]; then
      IFS=',' read -ra name_list <<<"${names}"
      for key in "${name_list[@]}"; do
        [[ -n "${key}" ]] && _lang_canon["${key}"]="${a2}"
      done
    fi
  done <<'EOF'
aa|aar||afar
ab|abk||abkhazian
ae|ave||avestan
af|afr||afrikaans
ak|aka||akan
am|amh||amharic
an|arg||aragonese
ar|ara||arabic
as|asm||assamese
av|ava||avaric
ay|aym||aymara
az|aze||azerbaijani
ba|bak||bashkir
be|bel||belarusian
bg|bul||
bi|bis||bislama
bm|bam||bambara
bn|ben||bengali
bo|tib|bod|tibetan
br|bre||breton
bs|bos||bosnian
ca|cat||catalan,valencian
ce|che||chechen
ch|cha||chamorro
co|cos||corsican
cr|cre||cree
cs|cze|ces|czech
cu|chu||slavic,church slavic,old slavonic,church slavonic,old church slavonic,slavonic,old bulgarian
cv|chv||chuvash
cy|wel|cym|welsh
da|dan||danish
de|ger|deu|german
dv|div||maldivian,dhivehi,divehi
dz|dzo||dzongkha
ee|ewe||ewe
el|gre|ell|greek,modern greek
en|eng||english
eo|epo||esperanto
es|spa||castilian,spanish
et|est||estonian
eu|baq|eus|basque
fa|per|fas|persian
ff|ful||fulah
fi|fin||finnish
fj|fij||fijian
fo|fao||faroese
fr|fre|fra|french
fy|fry||frisian,western frisian
ga|gle||irish
gd|gla||scottish gaelic,gaelic
gl|glg||galician
gn|grn||guarani
gu|guj||gujarati
gv|glv||manx
ha|hau||hausa
he|heb||hebrew
hi|hin||hindi
ho|hmo||motu,hiri motu
hr|hrv||croatian
ht|hat||haitian creole,creole,haitian
hu|hun||hungarian
hy|arm|hye|armenian
hz|her||herero
ia|ina||interlingua
id|ind||indonesian
ie|ile||occidental,interlingue
ig|ibo||igbo
ii|iii||yi,nuosu,sichuan yi
ik|ipk||inupiaq
io|ido||ido
is|ice|isl|icelandic
it|ita||italian
iu|iku||inuktitut
ja|jpn||japanese
jv|jav||javanese
ka|geo|kat|georgian
kg|kon||kongo
ki|kik||gikuyu,kikuyu
kj|kua||kuanyama,kwanyama
kk|kaz||kazakh
kl|kal||greenlandic,kalaallisut
km|khm||khmer,central khmer
kn|kan||kannada
ko|kor||korean
kr|kau||kanuri
ks|kas||kashmiri
ku|kur||kurdish
kv|kom||komi
kw|cor||cornish
ky|kir||kyrgyz,kirghiz
la|lat||latin
lb|ltz||letzeburgesch,luxembourgish
lg|lug||ganda
li|lim||limburgan,limburgish,limburger
ln|lin||lingala
lo|lao||lao
lt|lit||lithuanian
lu|lub||luba-katanga
lv|lav||latvian
mg|mlg||malagasy
mh|mah||marshallese
mi|mao|mri|maori
mk|mac|mkd|macedonian
ml|mal||malayalam
mn|mon||mongolian
mr|mar||marathi
ms|may|msa|malay
mt|mlt||maltese
my|bur|mya|burmese
na|nau||nauru
nb|nob||bokmål,norwegian bokmål
nd|nde||north ndebele
ne|nep||nepali
ng|ndo||ndonga
nl|dut|nld|flemish,dutch
nn|nno||nynorsk,norwegian nynorsk
no|nor||norwegian
nr|nbl||south ndebele
nv|nav||navaho,navajo
ny|nya||nyanja,chichewa,chewa
oc|oci||occitan
oj|oji||ojibwa
om|orm||oromo
or|ori||oriya
os|oss||ossetic,ossetian
pa|pan||panjabi,punjabi
pi|pli||pali
pl|pol||polish
ps|pus||pashto,pushto
pt|por||portuguese
qu|que||quechua
rm|roh||romansh
rn|run||rundi
ro|rum|ron|moldavian,romanian,moldovan
ru|rus||russian
rw|kin||kinyarwanda
sa|san||sanskrit
sc|srd||sardinian
sd|snd||sindhi
se|sme||northern sami,sami
sg|sag||sango
si|sin||sinhala,sinhalese
sk|slo|slk|slovak
sl|slv||slovenian
sm|smo||samoan
sn|sna||shona
so|som||somali
sq|alb|sqi|albanian
sr|srp||serbian
ss|ssw||swati
st|sot||sotho
su|sun||sundanese
sv|swe||swedish
sw|swa||swahili
ta|tam||tamil
te|tel||telugu
tg|tgk||tajik
th|tha||thai
ti|tir||tigrinya
tk|tuk||turkmen
tl|tgl||tagalog
tn|tsn||tswana
to|ton||tonga
tr|tur||turkish
ts|tso||tsonga
tt|tat||tatar
tw|twi||twi
ty|tah||tahitian
ug|uig||uyghur,uighur
uk|ukr||ukrainian
ur|urd||urdu
uz|uzb||uzbek
ve|ven||venda
vi|vie||vietnamese
vo|vol||volapük
wa|wln||walloon
wo|wol||wolof
xh|xho||xhosa
yi|yid||yiddish
yo|yor||yoruba
za|zha||chuang,zhuang
zh|chi|zho|chinese
zu|zul||zulu
EOF
}

########################################
# Normalizes a language code or name to a canonical token so that equivalent
# forms compare equal (e.g. en == eng == english). Recognized languages
# canonicalize to their ISO 639-1 code via the lookup table; unrecognized input
# is returned lowercased and whitespace-stripped, and empty or explicitly
# undetermined input becomes "und".
# Globals:
#   _lang_canon
# Arguments:
#   raw: A language tag, code, or name (any case).
# Outputs:
#   The canonical token on stdout.
########################################
normalize_lang() {
  init_lang_map
  local raw="${1,,}"
  raw="${raw//[[:space:]]/}"
  [[ -z "${raw}" || "${raw}" == "und" || "${raw}" == "undetermined" ]] && {
    printf 'und'
    return
  }
  printf '%s' "${_lang_canon["${raw}"]:-${raw}}"
}

########################################
# Determines a sidecar subtitle's language from the dot-separated tokens that
# sit between the media base name and the subtitle extension (e.g. the
# "en.forced" in "Movie.en.forced.srt"). The first token that is not a known
# role flag is taken as the language; an empty token string yields "und".
# Globals:
#   _sidecar_flags
# Arguments:
#   middle: The dot-separated token string (may be empty).
# Outputs:
#   The normalized language token on stdout.
########################################
lang_from_tokens() {
  local middle="$1" token lang="" tl f is_flag
  local -a tokens

  [[ -n "${middle}" ]] || { normalize_lang ""; return; }

  IFS='.' read -ra tokens <<<"${middle}"
  for token in "${tokens[@]}"; do
    tl="${token,,}"
    is_flag=false
    for f in "${_sidecar_flags[@]}"; do
      [[ "${tl}" == "${f}" ]] && { is_flag=true; break; }
    done
    [[ "${is_flag}" == true ]] && continue
    lang="${token}"
    break
  done

  normalize_lang "${lang}"
}

########################################
# Detects embedded subtitle-track languages in a media file via ffprobe.
# Globals:
#   None
# Arguments:
#   path: The media file to inspect.
# Outputs:
#   Zero or more normalized language tokens, one per line (one per track).
########################################
detect_embedded_langs() {
  local path="$1" line
  while IFS= read -r line; do
    printf '%s\n' "$(normalize_lang "${line}")"
  done < <(ffprobe -v error -select_streams s \
    -show_entries stream_tags=language -of csv=p=0 -- "${path}" 2>/dev/null)
}

########################################
# Records one media file's subtitle findings into the global result arrays and
# aggregate counters. Languages present from each source are de-duplicated per
# file so a file is counted once per language per source.
# Globals:
#   _media_paths, _media_subs, _lang_files, _lang_emb, _lang_side,
#   _total, _with_subs, _emb_only, _side_only, _both
# Arguments:
#   path:      The media file path.
#   emb_list:  Newline-separated embedded language tokens (may be empty).
#   side_list: Newline-separated sidecar language tokens (may be empty).
########################################
record_file() {
  local path="$1" emb_list="$2" side_list="$3"
  local -A emb_set=() side_set=() any_set=()
  local lang subs=""

  while IFS= read -r lang; do
    [[ -n "${lang}" ]] || continue
    emb_set["${lang}"]=1
    any_set["${lang}"]=1
  done <<<"${emb_list}"

  while IFS= read -r lang; do
    [[ -n "${lang}" ]] || continue
    side_set["${lang}"]=1
    any_set["${lang}"]=1
  done <<<"${side_list}"

  for lang in "${!emb_set[@]}"; do
    subs+="${subs:+ }${lang}:emb"
    _lang_emb["${lang}"]=$(( ${_lang_emb["${lang}"]:-0} + 1 ))
  done
  for lang in "${!side_set[@]}"; do
    subs+="${subs:+ }${lang}:side"
    _lang_side["${lang}"]=$(( ${_lang_side["${lang}"]:-0} + 1 ))
  done
  for lang in "${!any_set[@]}"; do
    _lang_files["${lang}"]=$(( ${_lang_files["${lang}"]:-0} + 1 ))
  done

  _media_paths+=("${path}")
  _media_subs+=("${subs}")

  _total=$(( _total + 1 ))
  if (( ${#any_set[@]} > 0 )); then
    _with_subs=$(( _with_subs + 1 ))
    if (( ${#emb_set[@]} > 0 && ${#side_set[@]} > 0 )); then
      _both=$(( _both + 1 ))
    elif (( ${#emb_set[@]} > 0 )); then
      _emb_only=$(( _emb_only + 1 ))
    else
      _side_only=$(( _side_only + 1 ))
    fi
  fi
}

########################################
# Recursively traverses a directory tree, processing every media file it finds.
# Symlinks are skipped to avoid cycles. Each directory is read exactly once: its
# entries are classified into media files and subtitle files in a single pass,
# then every media file is matched against the in-memory list of sibling
# subtitles (unless --no-sidecars) and, unless --no-embedded, probed for
# embedded tracks. Embedded progress is reported to stderr because that scan
# costs roughly 50-70 ms per file.
# Globals:
#   _media_exts, _subtitle_exts, _no_embedded, _no_sidecars,
#   _C_DIM, _C_YELLOW, _C_RESET
# Arguments:
#   dir: The directory to traverse.
########################################
traverse_tree() {
  local dir="$1"
  local entry fname ext extl el
  local -a media=()    # media file paths in this directory
  local -a subs=()      # subtitle file names (basenames) in this directory

  while IFS= read -r -d '' entry; do
    [[ -L "${entry}" ]] && continue

    if [[ -d "${entry}" ]]; then
      traverse_tree "${entry}"
      continue
    fi

    fname="$(basename "${entry}")"
    [[ "${fname}" == *.* ]] || continue
    ext="${fname##*.}"
    extl="${ext,,}"

    for el in "${_media_exts[@]}"; do
      if [[ "${extl}" == "${el}" ]]; then
        media+=("${entry}")
        continue 2
      fi
    done

    if [[ "${_no_sidecars}" != true ]]; then
      for el in "${_subtitle_exts[@]}"; do
        if [[ "${extl}" == "${el}" ]]; then
          subs+=("${fname}")
          continue 2
        fi
      done
    fi
  done < <(find "${dir}" -maxdepth 1 -mindepth 1 -print0 | sort -z)

  (( ${#media[@]} > 0 )) || return 0

  local path base sname sstem mid emb_list side_list i=0
  for path in "${media[@]}"; do
    i=$(( i + 1 ))
    if [[ "${_no_embedded}" != true && -t 2 ]]; then
      printf '\r%s' "${_C_DIM}${_C_YELLOW}Probing ${dir} [${i}/${#media[@]}]${_C_RESET}" >&2
    fi

    fname="$(basename "${path}")"
    base="${fname%.*}"

    # Match sibling sidecars from the entries already collected for this
    # directory (no extra filesystem traversal). A subtitle file belongs to this
    # media file when its stem equals the base ("Movie.srt" -> und) or begins
    # with "base." ("Movie.en.forced.srt" -> first non-flag token).
    side_list=""
    if [[ "${_no_sidecars}" != true ]]; then
      for sname in "${subs[@]+"${subs[@]}"}"; do
        sstem="${sname%.*}"
        if [[ "${sstem}" == "${base}" ]]; then
          side_list+="${side_list:+$'\n'}$(lang_from_tokens "")"
        elif [[ "${sstem}" == "${base}."* ]]; then
          mid="${sstem#"${base}".}"
          side_list+="${side_list:+$'\n'}$(lang_from_tokens "${mid}")"
        fi
      done
    fi

    if [[ "${_no_embedded}" == true ]]; then
      emb_list=""
    else
      emb_list="$(detect_embedded_langs "${path}")"
    fi

    record_file "${path}" "${emb_list}" "${side_list}"
  done

  if [[ "${_no_embedded}" != true && -t 2 ]]; then
    printf '\r\033[K' >&2   # Clear the progress line.
  fi
}

########################################
# Returns the languages seen across all files, sorted with "und" last.
# Globals:
#   _lang_files
# Arguments:
#   None
# Outputs:
#   One normalized language token per line.
########################################
sorted_langs() {
  (( ${#_lang_files[@]} > 0 )) || return 0
  printf '%s\n' "${!_lang_files[@]}" \
    | sort | sed '/^und$/d'
  [[ -n "${_lang_files[und]:-}" ]] && printf 'und\n'
}

########################################
# Prints the always-on summary: totals, per-language coverage (split by source),
# and a by-source breakdown. When --lang is given, the per-language section is
# reduced to that single language with a "missing it" count.
# Globals:
#   _target_dir, _total, _with_subs, _lang_norm, _lang, _lang_files, _lang_emb,
#   _lang_side, _emb_only, _side_only, _both, and color globals.
# Arguments:
#   None
########################################
print_summary() {
  local none=$(( _total - _with_subs ))
  local pct=0
  (( _total > 0 )) && pct=$(( _with_subs * 100 / _total ))

  printf '\n%s\n' "${_C_BOLD}${_C_BRIGHT_GREEN}Scanned ${_total} media files under ${_target_dir}.${_C_RESET}"

  if (( _total == 0 )); then
    printf '%s\n' "${_C_YELLOW}No media files found.${_C_RESET}"
    return
  fi

  printf '%s\n' "${_C_BOLD}${_C_GREEN}${_with_subs} files (${pct}%) have subtitles · ${none} have none.${_C_RESET}"

  if [[ -n "${_lang_norm}" ]]; then
    local have="${_lang_files["${_lang_norm}"]:-0}"
    local miss=$(( _total - have ))
    printf '\n%s\n' "${_C_BOLD}${_C_GREEN}Language '${_lang}' (${_lang_norm}):${_C_RESET}"
    printf '%s\n' "${_C_CYAN}$(printf '  %d files have it (%d embedded, %d sidecar) · %d missing it.' \
      "${have}" "${_lang_emb["${_lang_norm}"]:-0}" "${_lang_side["${_lang_norm}"]:-0}" "${miss}")${_C_RESET}"
  else
    printf '\n%s\n' "${_C_BOLD}${_C_GREEN}By language:${_C_RESET}"
    local lang
    while IFS= read -r lang; do
      printf '%s\n' "${_C_CYAN}$(printf '  %-5s %4d files   (%4d embedded, %4d sidecar)' \
        "${lang}" "${_lang_files["${lang}"]}" "${_lang_emb["${lang}"]:-0}" "${_lang_side["${lang}"]:-0}")${_C_RESET}"
    done < <(sorted_langs)
  fi

  printf '\n%s\n' "${_C_BOLD}${_C_GREEN}By source:${_C_RESET}"
  printf '%s\n' "${_C_CYAN}$(printf '  embedded only %d · sidecar only %d · both %d' \
    "${_emb_only}" "${_side_only}" "${_both}")${_C_RESET}"
}

########################################
# Renders a file's subtitle tokens ("lang:src ...") as a human-readable string
# such as "en [emb,side], fr [side]".
# Globals:
#   None
# Arguments:
#   tokstr: The space-separated "lang:source" token string (may be empty).
# Outputs:
#   The formatted string on stdout (empty input yields nothing).
########################################
format_subs() {
  local tokstr="$1" tok lang src
  local -A srcs=()
  local -a order=()
  for tok in ${tokstr}; do
    lang="${tok%%:*}"
    src="${tok##*:}"
    [[ -n "${srcs["${lang}"]:-}" ]] || order+=("${lang}")
    srcs["${lang}"]+="${srcs["${lang}"]:+,}${src}"
  done
  local out="" lang_sorted
  while IFS= read -r lang_sorted; do
    out+="${out:+, }${lang_sorted} [${srcs["${lang_sorted}"]}]"
  done < <(printf '%s\n' "${order[@]}" | sort)
  printf '%s' "${out}"
}

########################################
# Lists every media file with its detected subtitles, grouped by directory.
# When --lang is set, each file is annotated as having or missing that language.
# Globals:
#   _media_paths, _media_subs, _lang_norm, _lang, and color globals.
# Arguments:
#   None
########################################
print_list() {
  printf '\n%s\n' "${_C_BOLD}${_C_GREEN}Per-file subtitle listing:${_C_RESET}"

  local dir last_dir="" i path subs label
  while IFS= read -r i; do
    path="${_media_paths[i]}"
    subs="${_media_subs[i]}"
    dir="$(dirname "${path}")"

    if [[ "${dir}" != "${last_dir}" ]]; then
      printf '\n%s\n' "${_C_BOLD}${_C_YELLOW}${dir}${_C_RESET}"
      last_dir="${dir}"
    fi

    if [[ -n "${_lang_norm}" ]]; then
      if [[ " ${subs} " == *" ${_lang_norm}:"* ]]; then
        label="${_C_GREEN}has ${_lang}${_C_RESET}"
      else
        label="${_C_MAGENTA}MISSING ${_lang}${_C_RESET}"
      fi
      printf '  %s  %s\n' "$(basename "${path}")" "${label}"
    elif [[ -n "${subs}" ]]; then
      printf '  %s%s%s  %s%s%s\n' \
        "${_C_WHITE}" "$(basename "${path}")" "${_C_RESET}" \
        "${_C_CYAN}" "$(format_subs "${subs}")" "${_C_RESET}"
    else
      printf '  %s%s%s  %s%s%s\n' \
        "${_C_WHITE}" "$(basename "${path}")" "${_C_RESET}" \
        "${_C_MAGENTA}" "(none)" "${_C_RESET}"
    fi
  done < <(sorted_file_indices)
}

########################################
# Lists media files missing subtitles, sorted by path. With --lang, lists files
# lacking that language; otherwise lists files with no subtitles at all.
# Globals:
#   _media_paths, _media_subs, _lang_norm, _lang, and color globals.
# Arguments:
#   None
########################################
print_missing() {
  local heading count=0 i path subs
  if [[ -n "${_lang_norm}" ]]; then
    heading="Media files missing '${_lang}' subtitles:"
  else
    heading="Media files with no subtitles:"
  fi
  printf '\n%s\n' "${_C_BOLD}${_C_GREEN}${heading}${_C_RESET}"

  while IFS= read -r i; do
    path="${_media_paths[i]}"
    subs="${_media_subs[i]}"
    if [[ -n "${_lang_norm}" ]]; then
      [[ " ${subs} " == *" ${_lang_norm}:"* ]] && continue
    else
      [[ -n "${subs}" ]] && continue
    fi
    printf '%s\n' "${_C_MAGENTA}${path}${_C_RESET}"
    count=$(( count + 1 ))
  done < <(sorted_file_indices)

  if (( count == 0 )); then
    printf '%s\n' "${_C_BRIGHT_GREEN}None — every media file is covered.${_C_RESET}"
  fi
}

########################################
# Emits media-file array indices ordered by file path, NUL-safe.
# Globals:
#   _media_paths
# Arguments:
#   None
# Outputs:
#   One array index per line, ordered by the corresponding path.
########################################
sorted_file_indices() {
  (( ${#_media_paths[@]} > 0 )) || return 0
  local i
  for i in "${!_media_paths[@]}"; do
    printf '%s\t%s\0' "${_media_paths[i]}" "${i}"
  done | sort -z | tr '\0' '\n' | cut -f2
}

########################################
# Main entry point.
# Globals:
#   _lang, _lang_norm, _target_dir, _do_list, _do_missing, and others.
# Arguments:
#   Command-line arguments.
########################################
main() {
  parse_options "$@"
  setup_colors

  if ! command -v ffprobe &>/dev/null && [[ "${_no_embedded}" != true ]]; then
    log_error "ffprobe (from ffmpeg) is required for embedded detection; install it or pass --no-embedded."
    exit 1
  fi

  # Config is optional: defaults apply when no .conf file is present.
  load_config &>/dev/null || true
  apply_config

  # Build the language lookup once in the parent shell; the per-file
  # command-substitution calls to normalize_lang inherit the populated array.
  init_lang_map

  [[ -n "${_lang}" ]] && _lang_norm="$(normalize_lang "${_lang}")"

  traverse_tree "${_target_dir}"

  print_summary

  if [[ "${_do_list}" == true ]]; then
    print_list
  elif [[ "${_do_missing}" == true ]]; then
    print_missing
  fi
}

main "$@"
