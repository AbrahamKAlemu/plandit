# Saved-place extraction research

**Research date:** October 16, 2026

## Executive decision

A consent-based save-to-map pipeline is feasible without scraping public feeds:

- TikTok's official oEmbed endpoint may return title/caption, author, thumbnail, and embed markup,
  but those descriptive fields are not reliable for every current public video. It does not provide
  transcripts, OCR, geotags, structured venues, or raw media.
- Instagram oEmbed is for front-end embedding only. Meta prohibits extracting, deriving, or
  persisting its metadata/content for another purpose, so it cannot be Plandit's extraction input.
- Instagram links should remain source references while the user supplies a place name, caption
  text, or optional screenshot. Screenshot OCR should run on-device with Apple Vision, and the user
  should be able to correct the extracted text before it is sent for place matching.
- Place resolution needs a licensed provider adapter. Google Places API (New) is the leading
  candidate; Foursquare Place Match and Apple `MKLocalSearch` should be benchmarked before build.
- No result becomes a map point until the user confirms the place.

## Capability matrix

| Source | Arbitrary shared URL | Usable extraction input | Important limits | Decision |
|---|---:|---|---|---|
| TikTok oEmbed | Yes, for available public videos | Caption/title, author, temporary thumbnail | No transcript, OCR, geotag, venue, audio, or video download | Use for MVP |
| TikTok Display API | No | Metadata for an authorizing user's own posts | OAuth and app approval; not arbitrary links | Defer |
| TikTok Research API | Broad after approval | Richer public metadata | Not-for-profit research eligibility | Do not use |
| Instagram oEmbed | Yes for supported public posts | Display only | Extraction and persistence for another purpose are prohibited | Reference/display only |
| Instagram Platform API | No general URL lookup | Authorized professional-account media | Business/Creator accounts, tokens, permissions, review | Not an MVP solution |
| User text/screenshot | Yes, through explicit user action | Typed text or on-device OCR | Requires clear consent and correction flow | Use for Instagram fallback |
| Page/media scraping | Technically possible | Unofficial page/media data | Platform terms, copyright, fragility, anti-abuse risk | Prohibited |

## Live URL verification

On October 21, 2026, the public share URL
`https://www.tiktok.com/t/ZTfDj7vmC/` was tested end to end:

- TikTok redirected it to
  `https://www.tiktok.com/@travelwithchyna/video/7655467577765793037`.
- Both the share URL and canonical video URL returned HTTP 200 from TikTok oEmbed.
- The oEmbed payload contained the player/embed product ID and iframe markup but omitted `title`,
  `author_name`, `thumbnail_url`, caption text, transcript, and location evidence.
- The current client also rejected the `/t/<token>` share path because validation originally covered
  full `/@user/video/id` URLs plus `vm.tiktok.com` and `vt.tiktok.com`.

Therefore official oEmbed cannot be treated as a dependable arbitrary-URL evidence source. Accepting
and resolving TikTok share URLs is necessary URL plumbing, but it does not solve place extraction
when TikTok omits descriptive metadata.

## Place-provider options

| Provider | Strength | Cost/retention concern | Planning position |
|---|---|---|---|
| Google Places API (New) | Broad NYC coverage and strong free-text search | Field-mask pricing and restricted caching; Place IDs retainable | Primary candidate |
| Foursquare Places | Strong venue matching and Place Match | Smaller free allowance and field-retention restrictions | Benchmark challenger |
| Apple MapKit / `MKLocalSearch` | Native correction flow and no exposed server credential | No published native per-call quota; Apple-data storage limits | Manual correction/fallback |
| Yelp Places | Strong restaurant enrichment | Paid plans and substantial branding/cache requirements | Optional enrichment only |

No provider is approved by this document. Adding a service, paid API, or production credential
requires separate human approval at build kickoff.

## On-device evidence extraction

- Use Apple Vision text recognition for user-selected screenshots.
- Prefer local Speech framework transcription only for media the user separately supplies and is
  authorized to process.
- Do not download video or audio from a TikTok/Instagram URL.
- Send corrected text—not the screenshot—to the backend by default.
- Keep raw screenshots local unless a later, separately approved cloud-processing flow clearly
  explains retention and consent.

## URL and backend safety

- Accept HTTPS only.
- Allowlist supported TikTok and Instagram hosts.
- Resolve TikTok short links with a bounded redirect count and validate every hop.
- Reject credentials, nonstandard ports, private/loopback/link-local destinations, and hostname
  changes outside the allowlist.
- Strip tracking parameters and store canonical post identifiers where possible.
- Keep social/platform and place-provider credentials off-device.
- Never put raw screenshots, full extracted text, tokens, or signed media URLs in analytics/logs.

## Official sources

- [TikTok Embed Videos](https://developers.tiktok.com/docs/en/embed-videos)
- [TikTok Display API overview](https://developers.tiktok.com/docs/en/display-api-overview)
- [TikTok Query Videos](https://developers.tiktok.com/docs/en/tiktok-api-v2-video-query)
- [TikTok Research API codebook](https://developers.tiktok.com/docs/en/research-api-codebook)
- [TikTok U.S. Terms](https://www.tiktok.com/legal/page/us/terms-of-service/en)
- [Instagram oEmbed and limitations](https://developers.facebook.com/documentation/instagram-platform/oembed)
- [Instagram Platform overview](https://developers.facebook.com/documentation/instagram-platform/overview)
- [Instagram Media reference](https://developers.facebook.com/documentation/instagram-platform/reference/instagram-media)
- [Meta Automated Data Collection Terms](https://www.facebook.com/legal/automated_data_collection_terms)
- [Apple Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Google Places Text Search](https://developers.google.com/maps/documentation/places/web-service/text-search)
- [Google Places policies](https://developers.google.com/maps/documentation/places/web-service/policies)
- [Google Maps Platform pricing](https://developers.google.com/maps/billing-and-pricing/pricing)
- [Foursquare Place Match](https://docs.foursquare.com/fsq-developers-places/reference/place-match)
- [Foursquare usage guidelines](https://docs.foursquare.com/fsq-developers-places/reference/usage-guidelines)
- [Apple MKLocalSearch](https://developer.apple.com/documentation/mapkit/mklocalsearch)
- [Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
