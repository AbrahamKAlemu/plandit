# Social URL provider evaluation

**Research date:** October 21, 2026

## Conclusion

No official TikTok or Instagram API supports Plandit's full requirement: accept an arbitrary public
short-video URL and return its caption plus spoken transcript for unrestricted commercial use.

- TikTok Display API is limited to videos owned by an OAuth-authorized creator.
- TikTok Research API has restricted research-purpose approval and no verified transcript response.
- Instagram APIs are centered on authenticated professional accounts; Business Discovery is not an
  arbitrary-Reel-URL lookup and no official transcript field is documented.
- An LLM cannot solve content acquisition. It becomes useful only after a permitted provider or the
  user supplies caption, subtitle, transcript, or OCR evidence.

The best development evaluation is a provider comparison, not an immediate production dependency:

1. Apify for direct TikTok/Instagram URL coverage and claimed subtitle/transcript output.
2. Bright Data as the strongest documented operational caption/metadata baseline.
3. EnsembleData as a TikTok platform-subtitle comparator.
4. A small text-only LLM for structured place hypotheses.
5. Google Places or another licensed place provider for deterministic validation.

This is not a legal approval. Any public-web collection dependency requires counsel and contract
review before production.

## Provider shortlist

| Provider | URL coverage | Caption | Transcript/subtitles | Retention and operational notes | Position |
|---|---|---|---|---|---|
| Apify Instagram Reel Scraper | Arbitrary Reel URL claimed | Yes | Transcript claimed | Default run storage is too long; integration must delete datasets immediately | Best Instagram development evaluation |
| Clockworks TikTok Scraper on Apify | Arbitrary TikTok URL claimed | Yes | TikTok subtitles; video and subtitle downloads configurable separately | Community-maintained actor; platform and maintenance risk | Best TikTok development evaluation |
| Bright Data | Direct TikTok and Instagram URL collection | Yes | Not advertised | API/webhook operation, enterprise SLA options, documented 7-16 day result retention | Best production-engineering baseline if approved |
| EnsembleData | TikTok video metadata | Yes | Exposes TikTok subtitle URLs when available | Retention terms need diligence; not verified as platform-licensed | TikTok transcript comparator |
| TikTok Marketing Partners | Contract-dependent | Possibly | Not publicly established | Strongest official relationship, likely enterprise sales/RFP | Best compliance investigation |
| Phyllo | Connected accounts only | Source-dependent | Not documented | Strong consent/deletion semantics, but wrong product shape | Reject for arbitrary URLs |
| Ayrshare | Connected accounts and publishing | Not arbitrary URL retrieval | Not documented | Wrong product shape | Reject |
| Oxylabs | TikTok Shop publicly documented | Not verified for ordinary videos/Reels | No | Would require custom scraping and parsing | Do not shortlist without written support |

## Recommended evidence order

1. Canonical URL, content ID, platform, and creator handle.
2. Creator-written caption.
3. Platform-provided subtitle track.
4. Platform location/geotag metadata.
5. Sparse on-device or permitted provider OCR.
6. Vendor-generated speech transcription.
7. Full multimodal video processing only as an explicitly approved exception.

Evidence must preserve provenance rather than merging everything into an unlabeled transcript.
Plandit should retain only the minimum text needed for correction and confirmation, never provider
media URLs or downloaded social video.

## LLM position

Use a small text model only after evidence acquisition. It should produce no more than three
structured hypotheses:

```json
{
  "hypotheses": [
    {
      "name": "Chubby Bowls",
      "address_fragment": "809 Broadway",
      "neighborhood": "Union Square",
      "city": "New York",
      "evidence_quotes": [
        "chubby bowls at 809 Broadway near 14th St., Union Square"
      ],
      "confidence": 0.91
    }
  ],
  "insufficient_evidence": false
}
```

Required controls:

- Strict JSON Schema and near-zero temperature.
- Maximum three hypotheses.
- Every claim requires an exact evidence quote.
- No invented city or address.
- Explicit insufficient-evidence result.
- LLM confidence never confirms a place.
- Every hypothesis must be validated through a place provider and confirmed by the user.

### Text model versus multimodal model

| Dimension | Small text model | Multimodal/video model |
|---|---|---|
| Input | Caption, subtitle, transcript, OCR | Audio, frames, or video |
| Privacy | Text only | Media leaves the device/provider boundary |
| Cost and latency | Lower and predictable | Higher upload and processing cost |
| Best use | Place/entity extraction from available text | Visual-only place clues or missing transcript |
| Provenance | Exact evidence quotes | Requires timestamp/frame citations |
| Recommendation | Default | Exception path only |

## Twenty-URL evaluation

Use ten public TikToks and ten public Instagram Reels:

- Exact venue and address in caption.
- Venue and city only in caption.
- Spoken-only venue.
- Spoken-only street/intersection.
- Place visible only on a sign or menu.
- Ambiguous chain with neighborhood clue.
- Non-English caption or narration.
- Two places in one video.
- No identifiable place.
- Short/redirect share URL.

For each provider and URL, record:

- Canonical URL success.
- Caption and subtitle availability.
- Transcript language and provenance.
- Whether media was transferred or retained.
- Latency and retry count.
- LLM evidence quotes and hypotheses.
- Place-provider top three and selected stable place ID.
- Cost.
- Provider deletion request and confirmation.

## Pass/fail gates

Hard fail:

- Raw media remains in Plandit-controlled storage.
- Provider cannot explain media processing or retention.
- No deletion control or contractual deletion window.
- Private/login-gated content is accessed.
- Output lacks source/content ID or provenance.
- A place-free video produces a confident place.

Quality thresholds across accessible URLs:

- URL resolution: at least 90% overall and 85% per platform.
- Caption retrieval: at least 90% when a caption is visibly present.
- Native subtitle retrieval: at least 75% when subtitles visibly exist.
- Top-one exact venue/branch accuracy: at least 85%.
- Top-three recall: at least 95%.
- Wrong-city acceptance: 0%.
- Place-free false-positive rate: 0%.
- Strict-schema and evidence-quote compliance: 100%.
- Median acquisition latency: at most 10 seconds.
- P95 full-pipeline latency: at most 60 seconds.
- Immediate deletion request success: 100%.

## Production direction

1. Pursue official/authorized access through TikTok Marketing Partners and Meta written permission.
2. If counsel approves public-data collection, compare Bright Data metadata with a transcript
   specialist and use provider abstraction plus immediate deletion.
3. Use an Apify-only path, if approved, only for an early low-volume beta with video downloads
   disabled and run storage deleted immediately.
4. If authorization cannot be obtained, retain the consent-based URL/share-text and user-provided
   video flow.

## Sources

- [TikTok Display API](https://developers.tiktok.com/docs/en/display-api-get-started)
- [TikTok Research API](https://developers.tiktok.com/docs/en/research-api-get-started)
- [TikTok Developer Terms](https://www.tiktok.com/legal/page/global/tik-tok-developer-terms-of-service/en)
- [TikTok Content and Community Management Partners](https://ads.tiktok.com/business/en-US/blog/introducing-content-marketing-partners)
- [Instagram API with Instagram Login](https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-instagram-login)
- [Instagram Business Discovery](https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-facebook-login/business-discovery)
- [Meta Automated Data Collection Terms](https://www.facebook.com/legal/automated_data_collection_terms)
- [Apify Instagram Reel Scraper](https://apify.com/apify/instagram-reel-scraper)
- [Clockworks TikTok Scraper](https://apify.com/clockworks/tiktok-scraper)
- [Apify storage](https://docs.apify.com/storage)
- [Bright Data social scraper APIs](https://docs.brightdata.com/api-reference/scrapers/social-media-apis/overview)
- [Bright Data TikTok Scraper](https://brightdata.com/products/web-scraper/tiktok)
- [Bright Data retention specifications](https://docs.brightdata.com/products/scraper-studio/specifications)
- [EnsembleData TikTok transcript guide](https://ensembledata.com/blog/tiktok-transcript-generator-api-extract-text-from-video-automatically/)
- [OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
- [OpenAI API data controls](https://developers.openai.com/api/docs/guides/your-data)
- [Gemini structured output](https://ai.google.dev/gemini-api/docs/structured-output)
- [Gemini video understanding](https://ai.google.dev/gemini-api/docs/generate-content/video-understanding)
- [Google Places Text Search](https://developers.google.com/maps/documentation/places/web-service/text-search)
