package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unsafe"

	"github.com/PuerkitoBio/goquery"
	utls "github.com/refraction-networking/utls"
	"golang.org/x/net/http2"
)

const superFlixBase = "https://superflixapi.best"
// Canonical SuperFlix host (per GoAnime). Older hosts (.rest/.online) now
// 301-redirect here; the http.Client follows the redirect but downgrades POST
// to GET, so we target .best directly.
const superFlixUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

var sfClient = newHTTPClient()

func newHTTPClient() *http.Client {
	dialer := &net.Dialer{
		Timeout:   30 * time.Second,
		KeepAlive: 30 * time.Second,
	}

	utlsDial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		conn, err := dialer.DialContext(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		tlsConn := utls.UClient(conn, &utls.Config{
			ServerName: strings.Split(addr, ":")[0],
		}, utls.HelloChrome_Auto)
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			return nil, err
		}
		return tlsConn, nil
	}

	// HTTP/2 transport with uTLS
	h2Transport := &http2.Transport{
		DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
			return utlsDial(ctx, network, addr)
		},
		DisableCompression: false,
		IdleConnTimeout:    90 * time.Second,
	}

	return &http.Client{
		Timeout:   30 * time.Second,
		Transport: h2Transport,
	}
}

// --- JSON types for output ---

type SearchResult struct {
	Title    string `json:"title"`
	Year     string `json:"year"`
	Type     string `json:"type"`
	SFType   string `json:"sfType"`
	TMDBID   string `json:"tmdbId"`
	IMDBID   string `json:"imdbId"`
	ImageURL string `json:"imageUrl"`
}

type EpisodeItem struct {
	Number  string `json:"number"`
	Title   string `json:"title"`
	AirDate string `json:"airDate"`
}

type EpisodesResult struct {
	Seasons map[string][]EpisodeItem `json:"seasons"`
	Error   string                   `json:"error,omitempty"`
}

type StreamResult struct {
	StreamURL    string   `json:"streamUrl"`
	Title        string   `json:"title"`
	Referer      string   `json:"referer"`
	Subtitles    []Sub    `json:"subtitles"`
	DefaultAudio []string `json:"defaultAudio"`
	Thumb        string   `json:"thumb"`
	Error        string   `json:"error,omitempty"`
}

type Sub struct {
	Lang string `json:"lang"`
	URL  string `json:"url"`
}

// --- C-compatible exports ---

//export SearchSuperFlix
func SearchSuperFlix(query *C.char, result **C.char) int {
	q := C.GoString(query)
	results, err := searchMedia(context.Background(), q)
	if err != nil {
		*result = C.CString(fmt.Sprintf(`{"error":"%s"}`, err.Error()))
		return -1
	}
	b, _ := json.Marshal(results)
	*result = C.CString(string(b))
	return 0
}

//export GetSuperFlixEpisodes
func GetSuperFlixEpisodes(tmdbID *C.char, result **C.char) int {
	id := C.GoString(tmdbID)
	seasons, err := getEpisodes(context.Background(), id)
	if err != nil {
		*result = C.CString(fmt.Sprintf(`{"error":"%s"}`, err.Error()))
		return -1
	}
	resp := EpisodesResult{Seasons: seasons}
	b, _ := json.Marshal(resp)
	*result = C.CString(string(b))
	return 0
}

//export GetSuperFlixStream
func GetSuperFlixStream(tmdbID, season, episode *C.char, result **C.char) int {
	id := C.GoString(tmdbID)
	s := C.GoString(season)
	e := C.GoString(episode)
	stream, err := getStreamURL(context.Background(), id, s, e)
	if err != nil {
		*result = C.CString(fmt.Sprintf(`{"error":"%s"}`, err.Error()))
		return -1
	}
	b, _ := json.Marshal(stream)
	*result = C.CString(string(b))
	return 0
}

//export FreeCString
func FreeCString(str *C.char) {
	C.free(unsafe.Pointer(str))
}

// --- HTTP helpers ---

func doGET(ctx context.Context, urlStr string, headers map[string]string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", urlStr, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", superFlixUserAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	req.Header.Set("Accept-Language", "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	return sfClient.Do(req)
}

func doPOST(ctx context.Context, urlStr, body string, headers map[string]string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, "POST", urlStr, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", superFlixUserAgent)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	return sfClient.Do(req)
}

func readBody(resp *http.Response) (string, error) {
	body, err := io.ReadAll(io.LimitReader(resp.Body, 5*1024*1024))
	if err != nil {
		return "", err
	}
	return string(body), nil
}

// --- Search ---

func searchMedia(ctx context.Context, query string) ([]SearchResult, error) {
	normalized := strings.TrimSpace(query)
	normalized = strings.ReplaceAll(normalized, "-", " ")
	normalized = strings.ReplaceAll(normalized, "_", " ")

	searchURL := fmt.Sprintf("%s/pesquisar?s=%s", superFlixBase, url.QueryEscape(normalized))

	resp, err := doGET(ctx, searchURL, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}

	doc, err := goquery.NewDocumentFromReader(resp.Body)
	if err != nil {
		return nil, err
	}

	return parseCards(doc), nil
}

func parseCards(doc *goquery.Document) []SearchResult {
	var results []SearchResult
	seen := make(map[string]bool)

	doc.Find("div.group\\/card").Each(func(i int, card *goquery.Selection) {
		var title, imageURL string
		img := card.Find("img")
		if img.Length() > 0 {
			title, _ = img.Attr("alt")
			if src, ok := img.Attr("src"); ok && src != "" && !strings.HasPrefix(src, "data:") {
				imageURL = src
			}
			if imageURL == "" {
				if dataSrc, ok := img.Attr("data-src"); ok && dataSrc != "" {
					imageURL = dataSrc
				}
			}
			if imageURL == "" {
				if srcset, ok := img.Attr("srcset"); ok && srcset != "" {
					parts := strings.Fields(strings.Split(srcset, ",")[0])
					if len(parts) > 0 {
						imageURL = parts[0]
					}
				}
			}
		}
		if title == "" {
			if h3 := card.Find("h3"); h3.Length() > 0 {
				title = strings.TrimSpace(h3.Text())
			}
		}
		if title == "" {
			return
		}

		var tmdbID, imdbID string
		card.Find("button").Each(func(_ int, btn *goquery.Selection) {
			msg, _ := btn.Attr("data-msg")
			copyVal, _ := btn.Attr("data-copy")
			switch {
			case strings.Contains(msg, "TMDB"):
				tmdbID = copyVal
			case strings.Contains(msg, "IMDB"):
				imdbID = copyVal
			}
		})

		var tipo, year string
		card.Find("div.mt-3 span").Each(func(_ int, span *goquery.Selection) {
			text := strings.TrimSpace(span.Text())
			if text == "" {
				return
			}
			if len(text) == 4 && (text[0] == '1' || text[0] == '2') {
				if _, err := fmt.Sscanf(text, "%d", new(int)); err == nil {
					year = text
					return
				}
			}
			tipo = text
		})

		if tmdbID == "" {
			card.Find("button").Each(func(_ int, btn *goquery.Selection) {
				msg, _ := btn.Attr("data-msg")
				if strings.Contains(msg, "Link") {
					link, _ := btn.Attr("data-copy")
					if strings.Contains(link, "/serie/") {
						parts := strings.Split(link, "/serie/")
						if len(parts) > 1 {
							tmdbID = strings.Split(parts[1], "?")[0]
						}
					} else if strings.Contains(link, "/filme/") {
						parts := strings.Split(link, "/filme/")
						if len(parts) > 1 {
							tmdbID = strings.Split(parts[1], "?")[0]
						}
					}
				}
			})
		}

		if tmdbID == "" {
			return
		}
		if seen[tmdbID] {
			return
		}
		seen[tmdbID] = true

		sfType := "serie"
		if tipo == "Filme" || strings.Contains(imdbID, "filme") {
			sfType = "filme"
		}
		if tipo == "" {
			tipo = "Série"
		}

		results = append(results, SearchResult{
			Title:    title,
			Year:     year,
			Type:     tipo,
			SFType:   sfType,
			TMDBID:   tmdbID,
			IMDBID:   imdbID,
			ImageURL: normalizeImageURL(imageURL),
		})
	})

	return results
}

func normalizeImageURL(imageURL string) string {
	if imageURL == "" {
		return ""
	}
	const tmdbPrefix = "https://image.tmdb.org/t/p/"
	if idx := strings.Index(imageURL, tmdbPrefix); idx > 0 {
		direct := imageURL[idx:]
		direct = strings.ReplaceAll(direct, "/w342/", "/w500/")
		direct = strings.ReplaceAll(direct, "/w185/", "/w500/")
		direct = strings.ReplaceAll(direct, "/w154/", "/w500/")
		return direct
	}
	return imageURL
}

// --- Episodes ---

func getEpisodes(ctx context.Context, tmdbID string) (map[string][]EpisodeItem, error) {
	pageURL := fmt.Sprintf("%s/serie/%s", superFlixBase, tmdbID)
	resp, err := doGET(ctx, pageURL, map[string]string{"Referer": superFlixBase + "/"})
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	html, err := readBody(resp)
	if err != nil {
		return nil, err
	}

	allEpisodesRe := regexp.MustCompile(`var ALL_EPISODES\s*=\s*(\{.+?\});`)
	m := allEpisodesRe.FindStringSubmatch(html)
	if len(m) < 2 {
		return nil, nil
	}

	var raw map[string][]struct {
		EpiNum  json.Number `json:"epi_num"`
		Title   string      `json:"title"`
		AirDate string      `json:"air_date"`
	}
	if err := json.Unmarshal([]byte(m[1]), &raw); err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)

	seasons := make(map[string][]EpisodeItem)
	for season, episodes := range raw {
		var items []EpisodeItem
		for _, ep := range episodes {
			if ep.AirDate == "" || ep.AirDate == "null" {
				continue
			}
			if t, err := time.Parse("2006-01-02", ep.AirDate); err == nil {
				if t.After(today) {
					continue
				}
			}
			items = append(items, EpisodeItem{
				Number:  ep.EpiNum.String(),
				Title:   ep.Title,
				AirDate: ep.AirDate,
			})
		}
		if len(items) > 0 {
			seasons[season] = items
		}
	}

	return seasons, nil
}

// --- Stream URL ---

func getStreamURL(ctx context.Context, tmdbID, season, episode string) (*StreamResult, error) {
	if season == "" || episode == "" || season == "0" {
		return nil, fmt.Errorf("season and episode required")
	}

	pageURL := fmt.Sprintf("%s/serie/%s/%s/%s", superFlixBase, tmdbID, season, episode)
	resp, err := doGET(ctx, pageURL, map[string]string{"Referer": superFlixBase + "/"})
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	html, err := readBody(resp)
	if err != nil {
		return nil, err
	}

	csrfRe := regexp.MustCompile(`var CSRF_TOKEN\s*=\s*"([^"]+)"`)
	pageTokenRe := regexp.MustCompile(`var PAGE_TOKEN\s*=\s*"([^"]+)"`)
	contentIDRe := regexp.MustCompile(`var INITIAL_CONTENT_ID\s*=\s*(\d+)`)
	contentTypeRe := regexp.MustCompile(`var CONTENT_TYPE\s*=\s*"([^"]+)"`)
	titleRe := regexp.MustCompile(`<title>(?:Player \| )?(.+?)</title>`)

	csrf := ""
	pageToken := ""
	contentID := ""
	contentType := ""
	title := ""

	if m := csrfRe.FindStringSubmatch(html); len(m) > 1 {
		csrf = m[1]
	}
	if m := pageTokenRe.FindStringSubmatch(html); len(m) > 1 {
		pageToken = m[1]
	}
	if m := contentIDRe.FindStringSubmatch(html); len(m) > 1 {
		contentID = m[1]
	}
	if m := contentTypeRe.FindStringSubmatch(html); len(m) > 1 {
		contentType = m[1]
	}
	if m := titleRe.FindStringSubmatch(html); len(m) > 1 {
		title = m[1]
	}

	if csrf == "" || pageToken == "" {
		return nil, fmt.Errorf("failed to extract tokens from player page")
	}

	bootstrapURL := superFlixBase + "/player/bootstrap"
	form := url.Values{
		"contentid":  {contentID},
		"type":       {contentType},
		"_token":     {csrf},
		"page_token": {pageToken},
		"pageToken":  {pageToken},
	}.Encode()

	bresp, err := doPOST(ctx, bootstrapURL, form, map[string]string{
		"Content-Type":     "application/x-www-form-urlencoded",
		"Referer":          superFlixBase + "/",
		"X-Page-Token":     pageToken,
		"X-Requested-With": "XMLHttpRequest",
		"Origin":           superFlixBase,
	})
	if err != nil {
		return nil, err
	}
	defer bresp.Body.Close()

	bbody, err := io.ReadAll(io.LimitReader(bresp.Body, 2*1024*1024))
	if err != nil {
		return nil, err
	}

	if len(bbody) > 0 && bbody[0] == '<' {
		return nil, fmt.Errorf("bootstrap returned HTML (blocked)")
	}

	var bootstrap struct {
		Data struct {
			Options []struct {
				ID   json.RawMessage `json:"ID"`
				Name string          `json:"name"`
			} `json:"options"`
		} `json:"data"`
	}
	if err := json.Unmarshal(bbody, &bootstrap); err != nil {
		return nil, fmt.Errorf("bootstrap decode: %w", err)
	}

	if len(bootstrap.Data.Options) == 0 {
		return nil, fmt.Errorf("no servers available")
	}

	videoID := ""
	for _, s := range bootstrap.Data.Options {
		var raw string
		if err := json.Unmarshal(s.ID, &raw); err == nil && !strings.HasPrefix(raw, "fallback") {
			videoID = raw
			break
		}
		var num json.Number
		if err := json.Unmarshal(s.ID, &num); err == nil {
			videoID = num.String()
			break
		}
	}
	if videoID == "" {
		var raw string
		_ = json.Unmarshal(bootstrap.Data.Options[0].ID, &raw)
		videoID = raw
	}

	sourceURL := superFlixBase + "/player/source"
	sform := url.Values{
		"video_id":   {videoID},
		"page_token": {pageToken},
		"host":       {""},
		"site":       {""},
		"_token":     {csrf},
	}.Encode()

	sresp, err := doPOST(ctx, sourceURL, sform, map[string]string{
		"Content-Type":     "application/x-www-form-urlencoded",
		"Referer":          superFlixBase + "/",
		"X-Page-Token":     pageToken,
		"X-Requested-With": "XMLHttpRequest",
		"Origin":           superFlixBase,
	})
	if err != nil {
		return nil, err
	}
	defer sresp.Body.Close()

	sbody, err := io.ReadAll(io.LimitReader(sresp.Body, 1*1024*1024))
	if err != nil {
		return nil, err
	}

	if len(sbody) > 0 && sbody[0] == '<' {
		return nil, fmt.Errorf("source returned HTML (blocked)")
	}

	var sourceResp struct {
		Data struct {
			VideoURL string `json:"video_url"`
		} `json:"data"`
	}
	if err := json.Unmarshal(sbody, &sourceResp); err != nil {
		return nil, fmt.Errorf("source decode: %w", err)
	}

	if sourceResp.Data.VideoURL == "" {
		return nil, fmt.Errorf("no video URL in source response")
	}

	resolvedInfo, err := resolveRedirect(ctx, sourceResp.Data.VideoURL)
	if err != nil {
		return nil, fmt.Errorf("resolve redirect: %w", err)
	}

	streamURL, err := getVideoAPI(ctx, resolvedInfo.baseURL, resolvedInfo.videoHash, resolvedInfo.referer)
	if err != nil {
		return nil, fmt.Errorf("video API: %w", err)
	}

	result := &StreamResult{
		StreamURL: streamURL,
		Title:     title,
		Referer:   resolvedInfo.playerBase + "/",
		Thumb:     "",
	}

	result.Subtitles, result.DefaultAudio = extractPlayerExtras(resolvedInfo.playerHTML)

	return result, nil
}

type resolvedInfo struct {
	baseURL    string
	videoHash  string
	referer    string
	playerBase string
	playerHTML string
}

func resolveRedirect(ctx context.Context, redirectURL string) (*resolvedInfo, error) {
	// For redirect resolution, we use http2.Transport as well
	h2Transport := &http2.Transport{
		DialTLSContext: sfClient.Transport.(*http2.Transport).DialTLSContext,
	}

	// Use h2 transport for follow-up request
	req, err := http.NewRequestWithContext(ctx, "GET", redirectURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", superFlixUserAgent)
	req.Header.Set("Referer", superFlixBase + "/")
	req.Header.Set("Accept", "*/*")

	followClient := &http.Client{
		Timeout:   30 * time.Second,
		Transport: h2Transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return fmt.Errorf("too many redirects")
			}
			return nil
		},
	}

	fresp, err := followClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer fresp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(fresp.Body, 5*1024*1024))
	if err != nil {
		return nil, err
	}

	finalURL := fresp.Request.URL.String()

	var baseURL, videoHash string
	if strings.Contains(finalURL, "/video/") {
		parts := strings.SplitN(finalURL, "/video/", 2)
		baseURL = parts[0]
		videoHash = strings.SplitN(parts[1], "?", 2)[0]
		videoHash = strings.SplitN(videoHash, "#", 2)[0]
	} else {
		idx := strings.LastIndex(finalURL, "/")
		if idx > 0 {
			baseURL = finalURL[:idx]
			videoHash = strings.SplitN(finalURL[idx+1:], "?", 2)[0]
		}
	}

	return &resolvedInfo{
		baseURL:    baseURL,
		videoHash:  videoHash,
		referer:    fmt.Sprintf("%s/video/%s", baseURL, videoHash),
		playerBase: baseURL,
		playerHTML: string(body),
	}, nil
}

func getVideoAPI(ctx context.Context, playerBaseURL, videoHash, referer string) (string, error) {
	apiURL := fmt.Sprintf("%s/player/index.php?data=%s&do=getVideo", playerBaseURL, videoHash)
	form := url.Values{
		"hash": {videoHash},
		"r":    {superFlixBase + "/"},
	}.Encode()

	resp, err := doPOST(ctx, apiURL, form, map[string]string{
		"Content-Type":     "application/x-www-form-urlencoded",
		"Referer":          referer,
		"X-Requested-With": "XMLHttpRequest",
	})
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024))
	if err != nil {
		return "", err
	}

	if len(body) > 0 && body[0] == '<' {
		return "", fmt.Errorf("video API returned HTML (blocked)")
	}

	var result struct {
		SecuredLink string `json:"securedLink"`
		VideoSource string `json:"videoSource"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return "", err
	}

	switch {
	case result.SecuredLink != "":
		return result.SecuredLink, nil
	case result.VideoSource != "":
		return result.VideoSource, nil
	default:
		return "", fmt.Errorf("no stream URL in response")
	}
}

func extractPlayerExtras(html string) ([]Sub, []string) {
	subtitleRe := regexp.MustCompile(`var playerjsSubtitle\s*=\s*"(.+?)";`)
	audioRe := regexp.MustCompile(`var defaultAudio\s*=\s*(\[.+?\]);`)
	subPartRe := regexp.MustCompile(`\[(.+?)\](https?://.+)`)

	var subtitles []Sub
	var defaultAudio []string

	if m := audioRe.FindStringSubmatch(html); len(m) > 1 {
		_ = json.Unmarshal([]byte(m[1]), &defaultAudio)
	}

	if m := subtitleRe.FindStringSubmatch(html); len(m) > 1 {
		for _, part := range strings.Split(m[1], ",") {
			sm := subPartRe.FindStringSubmatch(part)
			if len(sm) > 2 {
				subtitles = append(subtitles, Sub{Lang: sm[1], URL: sm[2]})
			}
		}
	}

	return subtitles, defaultAudio
}

//export GetSuperFlixServers
func GetSuperFlixServers(tmdbID, season, episode *C.char, result **C.char) int {
	id := C.GoString(tmdbID)
	s := C.GoString(season)
	e := C.GoString(episode)
	servers, err := getServers(context.Background(), id, s, e)
	if err != nil {
		*result = C.CString(fmt.Sprintf(`{"error":"%s"}`, err.Error()))
		return -1
	}
	b, _ := json.Marshal(servers)
	*result = C.CString(string(b))
	return 0
}

// superFlixServer mirrors the bootstrap options entry.
type superFlixServer struct {
	ID   json.RawMessage `json:"ID"`
	Name string          `json:"name"`
}

// getServers resolves every non-fallback streaming server for an episode and
// returns one entry per server (stream URL + referer), so the TV UI can offer
// a real source/quality selection instead of a single arbitrary pick.
func getServers(ctx context.Context, tmdbID, season, episode string) ([]map[string]string, error) {
	if season == "" || episode == "" || season == "0" {
		return nil, fmt.Errorf("season and episode required")
	}

	pageURL := fmt.Sprintf("%s/serie/%s/%s/%s", superFlixBase, tmdbID, season, episode)
	resp, err := doGET(ctx, pageURL, map[string]string{"Referer": superFlixBase + "/"})
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	html, err := readBody(resp)
	if err != nil {
		return nil, err
	}

	csrf := firstGroup(html, `var CSRF_TOKEN\s*=\s*"([^"]+)"`)
	pageToken := firstGroup(html, `var PAGE_TOKEN\s*=\s*"([^"]+)"`)
	contentID := firstGroup(html, `var INITIAL_CONTENT_ID\s*=\s*(\d+)`)
	contentType := firstGroup(html, `var CONTENT_TYPE\s*=\s*"([^"]+)"`)
	if csrf == "" || pageToken == "" {
		return nil, fmt.Errorf("failed to extract tokens from player page")
	}
	tokens := struct {
		CSRF        string
		PageToken   string
		ContentID   string
		ContentType string
	}{csrf, pageToken, contentID, contentType}

	servers, err := bootstrapServers(ctx, tokens)
	if err != nil {
		return nil, err
	}
	if len(servers) == 0 {
		return nil, fmt.Errorf("no servers available")
	}

	var out []map[string]string
	for _, srv := range servers {
		videoID := parseServerID(srv.ID)
		if videoID == "" {
			continue
		}
		sourceURL, err := getSourceURLFor(ctx, videoID, tokens)
		if err != nil || sourceURL == "" {
			continue
		}
		resolved, err := resolveRedirect(ctx, sourceURL)
		if err != nil {
			continue
		}
		streamURL, err := getVideoAPI(ctx, resolved.baseURL, resolved.videoHash, resolved.referer)
		if err != nil || streamURL == "" {
			continue
		}
		out = append(out, map[string]string{
			"streamUrl": streamURL,
			"referer":   resolved.playerBase + "/",
			"name":      srv.Name,
		})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no stream URL resolved")
	}
	return out, nil
}

func firstGroup(html, pattern string) string {
	re := regexp.MustCompile(pattern)
	m := re.FindStringSubmatch(html)
	if len(m) > 1 {
		return m[1]
	}
	return ""
}

func parseServerID(raw json.RawMessage) string {
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		if !strings.HasPrefix(s, "fallback") {
			return s
		}
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err == nil {
		return n.String()
	}
	return ""
}

func bootstrapServers(ctx context.Context, tokens struct {
	CSRF        string
	PageToken   string
	ContentID   string
	ContentType string
}) ([]superFlixServer, error) {
	bootstrapURL := superFlixBase + "/player/bootstrap"
	form := url.Values{
		"contentid":  {tokens.ContentID},
		"type":       {tokens.ContentType},
		"_token":     {tokens.CSRF},
		"page_token": {tokens.PageToken},
		"pageToken":  {tokens.PageToken},
	}.Encode()

	bresp, err := doPOST(ctx, bootstrapURL, form, map[string]string{
		"Content-Type":     "application/x-www-form-urlencoded",
		"Referer":          superFlixBase + "/",
		"X-Page-Token":     tokens.PageToken,
		"X-Requested-With": "XMLHttpRequest",
		"Origin":           superFlixBase,
	})
	if err != nil {
		return nil, err
	}
	defer bresp.Body.Close()

	bbody, err := io.ReadAll(io.LimitReader(bresp.Body, 2*1024*1024))
	if err != nil {
		return nil, err
	}
	if len(bbody) > 0 && bbody[0] == '<' {
		return nil, fmt.Errorf("bootstrap returned HTML (blocked)")
	}

	var bootstrap struct {
		Data struct {
			Options []superFlixServer `json:"options"`
		} `json:"data"`
	}
	if err := json.Unmarshal(bbody, &bootstrap); err != nil {
		return nil, err
	}
	return bootstrap.Data.Options, nil
}

func getSourceURLFor(ctx context.Context, videoID string, tokens struct {
	CSRF        string
	PageToken   string
	ContentID   string
	ContentType string
}) (string, error) {
	sourceURL := superFlixBase + "/player/source"
	form := url.Values{
		"video_id":   {videoID},
		"page_token": {tokens.PageToken},
		"host":       {""},
		"site":       {""},
		"_token":     {tokens.CSRF},
	}.Encode()

	sresp, err := doPOST(ctx, sourceURL, form, map[string]string{
		"Content-Type":     "application/x-www-form-urlencoded",
		"Referer":          superFlixBase + "/",
		"X-Page-Token":     tokens.PageToken,
		"X-Requested-With": "XMLHttpRequest",
		"Origin":           superFlixBase,
	})
	if err != nil {
		return "", err
	}
	defer sresp.Body.Close()

	sbody, err := io.ReadAll(io.LimitReader(sresp.Body, 1*1024*1024))
	if err != nil {
		return "", err
	}
	if len(sbody) > 0 && sbody[0] == '<' {
		return "", fmt.Errorf("source returned HTML (blocked)")
	}

	var sourceResp struct {
		Data struct {
			VideoURL string `json:"video_url"`
		} `json:"data"`
	}
	if err := json.Unmarshal(sbody, &sourceResp); err != nil {
		return "", err
	}
	return sourceResp.Data.VideoURL, nil
}

func main() {}
