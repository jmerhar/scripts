# shellcheck shell=bash
#
# Turning whatever a subtitle or an audio track calls its language into one canonical code.
#
# The table is ISO 639: 183 languages, each with its two-letter code, its bibliographic and terminological
# three-letter codes, and its English names. Two scripts read media libraries and have to agree about what
# a language is called — a report saying a file has Vietnamese subtitles is no use if the tool that fetches
# them cannot match "vietnamese" to "vi".
#
# Two variables are this library's input, both optional:
#
#   _und_as_english   "true" to normalise an undetermined language to "en" rather than "und". Some releases
#                     ship untagged English subtitles, and a caller may prefer that reading.
#   _sidecar_flags    Role tokens that appear where a language would in a filename — "forced", "sdh" and
#                     the like. lang_from_tokens skips them rather than mistaking one for a language.
#
# Sourced at development time and inlined by compile-includes.sh at build time.

# Double-source guard
if [[ "${_LANG_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_LANG_SH_LOADED="true"

# Built on first use, since the table is long and a script may never look a language up.
declare -A _lang_canon=()
_lang_map_ready=false

# Defaults for the two inputs above, so a script that cares about neither need not define them. Assigned
# only when unset, so a caller's own values win.
_und_as_english="${_und_as_english:-false}"
if [[ -z "${_sidecar_flags+x}" ]]; then
  _sidecar_flags=(forced sdh cc hi default)
fi

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
        # Registered without whitespace, because normalize_lang strips it from what it looks up:
        # a multi-word name has to be keyed the same way on both sides to be reachable at all.
        # This also makes "modern greek", "Modern Greek" and "moderngreek" equivalent.
        key="${key//[[:space:]]/}"
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
bg|bul||bulgarian
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
normalize_lang() {
  init_lang_map
  local raw="${1,,}"
  raw="${raw//[[:space:]]/}"
  if [[ -z "${raw}" || "${raw}" == "und" || "${raw}" == "undetermined" ]]; then
    if [[ "${_und_as_english}" == true ]]; then
      printf 'en'
    else
      printf 'und'
    fi
    return
  fi
  printf '%s' "${_lang_canon["${raw}"]:-${raw}}"
}

########################################
lang_from_tokens() {
  local middle="$1" token lang="" tl f is_flag
  local -a tokens

  [[ -n "${middle}" ]] || { normalize_lang ""; return; }

  IFS='.' read -ra tokens <<<"${middle}"
  for token in "${tokens[@]}"; do
    tl="${token,,}"
    is_flag=false
    for f in ${_sidecar_flags[@]+"${_sidecar_flags[@]}"}; do
      [[ "${tl}" == "${f}" ]] && { is_flag=true; break; }
    done
    [[ "${is_flag}" == true ]] && continue
    lang="${token}"
    break
  done

  normalize_lang "${lang}"
}
