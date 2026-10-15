# Decision: image generation tier

- **Date:** 2026-10-15
- **Decided by:** owner (Thebigtuna88)
- **Status:** accepted

## Decision

**Tier C only for now.** Images are created outside the harness and dropped into
`assets/inbox/`. Paid image-API spend is $0. The provider adapter and budget wrapper are still
built (Phase 6), with `manual` as the only enabled provider, so adding a paid provider later
means writing an adapter, setting a cap and running an owner handoff.

## Prices researched 2026-10-15 (re-check before using)

| Provider | Model | Price | Billing | Source |
|---|---|---|---|---|
| Higgsfield API | Soul 2 / Soul Cinema | from ~$0.0032/image | prepaid USD balance, $5 min top-up, can't go below $0, optional auto top-up, funds expire after 1 year, failures refunded | higgsfield.ai/blog/higgsfield-api; higgsfield.ai help center |
| Higgsfield API | Marketing Studio Image | from ~$0.0059/image | as above | same |
| Higgsfield API | Ideogram 4.0 | ~$0.03/image | as above | layer3labs.io guide (third party) |
| fal.ai | FLUX.1 [schnell] | $0.003/megapixel | per megapixel, rounded up | fal.ai model page |
| fal.ai | FLUX.2 [dev] | $0.012/megapixel | per megapixel | fal.ai model page |
| fal.ai | FLUX.1 [dev] | $0.025/megapixel | per megapixel | fal.ai model page; modelslab.com |
| fal.ai | FLUX1.1 [pro] | ~$0.04/megapixel | per megapixel | modelslab.com (third party) |
| Replicate | FLUX.1 [schnell] | ~$0.003/image | per output image | replicate.com blog |
| Replicate | FLUX1.1 [pro] | $0.04/image | per output image | replicate.com blog + pricing |

Estimated cost for 200 drafts and 30 finals a month: about $1–$10 on any paid tier.
Recommended later path: Higgsfield with auto top-up **off**, so the prepaid wallet is a hard cap.

## Alternatives considered

Tier A (Higgsfield only), Tier B (fal.ai only), and a hybrid (fal.ai drafts, Higgsfield
finals). All are deferred, not rejected.
