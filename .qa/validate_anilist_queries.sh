#!/usr/bin/env bash
# Valida as queries GraphQL literais do AniListService contra o schema real
# (https://graphql.anilist.co). Roda no QA manual (Fase 6 do plano v2) porque
# o `flutter test` bloqueia rede. Se alguma query devolver != 200 ou `errors`,
# falha — o bug do "0 animes" foi exatamente query-vs-schema.
#
# Usage: USER_ID=123 .qa/validate_anilist_queries.sh
set -euo pipefail

API="https://graphql.anilist.co"
USER_ID="${USER_ID:-2}"   # usuário público de teste; 200 + grupos reais

# Fonte única das queries (mesma const que o teste T1 valida).
LIST_QUERY='query ($userId: Int) {
  MediaListCollection(userId: $userId, type: ANIME) {
    lists {
      name
      entries {
        progress
        status
        updatedAt
        media {
           id
           title { romaji english native }
           coverImage { large extraLarge }
           bannerImage
           episodes
           format
           status
           nextAiringEpisode { episode timeUntilAiring }
         }
      }
    }
  }
}'

ENRICH_QUERY='
        query ($search: String) {
          Media(search: $search, type: ANIME) {
            id
            idMal
            title { romaji english native }
            coverImage { extraLarge large medium }
            bannerImage
            description
            episodes
            status
            averageScore
            genres
            nextAiringEpisode { episode timeUntilAiring }
          }
        }
      '

VARIANTS_QUERY='
        query ($search: String) {
          Media(search: $search, type: ANIME) {
            id
            title { romaji english native }
          }
        }
      '

EPISODES_QUERY='
      query ($mediaId: Int) {
        Media(id: $mediaId) {
          id
          streamingEpisodes {
            title
            thumbnail
            url
            site
          }
        }
      }
    '

CATALOG_QUERY='
    query ($sort: [MediaSort], $season: MediaSeason, $seasonYear: Int, $perPage: Int) {
      Page(page: 1, perPage: $perPage) {
        media(type: ANIME, sort: $sort, season: $season, seasonYear: $seasonYear, isAdult: false) {
          id
          title { romaji english native }
          coverImage { extraLarge large medium }
          bannerImage
          description
          episodes
          status
          averageScore
          genres
        }
      }
    }
  '

check() {
  local name="$1" payload="$2"
  local respcode body
  body=$(curl -s -w '\n%{http_code}' -X POST "$API" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data "$payload")
  respcode="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [ "$respcode" != "200" ]; then
    echo "FAIL $name -> HTTP $respcode"
    echo "$body" | head -c 400
    echo
    return 1
  fi
  if printf '%s' "$body" | grep -q '"errors"'; then
    echo "FAIL $name -> GraphQL errors"
    echo "$body" | head -c 400
    echo
    return 1
  fi
  echo "OK   $name"
}

check "listQuery" "{\"query\":$(printf '%s' "$LIST_QUERY" | jq -Rs .),\"variables\":{\"userId\":$USER_ID}}"
check "enrich"  "{\"query\":$(printf '%s' "$ENRICH_QUERY" | jq -Rs .),\"variables\":{\"search\":\"one piece\"}}"
check "variants" "{\"query\":$(printf '%s' "$VARIANTS_QUERY" | jq -Rs .),\"variables\":{\"search\":\"one piece\"}}"
check "getEpisodesV2" "{\"query\":$(printf '%s' "$EPISODES_QUERY" | jq -Rs .),\"variables\":{\"mediaId\":21}}"
check "_catalogQuery" "{\"query\":$(printf '%s' "$CATALOG_QUERY" | jq -Rs .),\"variables\":{\"sort\":[\"TRENDING_DESC\"],\"perPage\":3}}"

echo "All queries valid."