# PocketAI launch runbook (owner actions → revenue)

Code is feature-complete + CI-green. These are the real-world steps left,
ordered for fastest first dollar. Items marked (me) I automate once you unblock.

## Phase 0 — Prove it runs on real hardware (the gate)
1. Unlock the iPhone 17 Pro, keep it awake, trust this Mac. (me) I then run:
   download a real model → load → generate on MLX + llama; record tok/s + memory.
2. Mac: run a model locally in the app. (me) verify on your dev Mac.
   → If both generate acceptably, you have a shippable product.

## Phase 1 — Mac direct sales (fastest money, NO Apple cut)
3. Apple Developer Program: already enrolled (Team 4RK6YA795V). In Xcode >
   Settings > Accounts > Manage Certificates, create a **Developer ID
   Application** cert.
4. Create a notarytool profile (one line, see scripts/notarize-mac.sh header).
5. (me) `scripts/notarize-mac.sh` → notarized **PocketAI.dmg**.
6. Payments: create a **Stripe Payment Link** ($39 launch). Confirm Stripe
   works for an India-based business selling internationally + tax duties.
7. Keygen: product + Pro policy already set (account 40fe7260…). Create a
   **Zapier** zap: Stripe "checkout completed" → Keygen "create license" →
   email the key + `pocketai://activate?k=` link to the buyer.
8. (me) Put the DMG + the real Stripe link on pocket.liveshortly.com (WEB-01 built),
   replace `STRIPE_PAYMENT_LINK_PLACEHOLDER`. → **You can take money.**

## Phase 2 — iOS App Store (parallel)
9. ASC → Users & Access → Integrations: copy the **Issuer ID**; you already
   have Key ID 784C9X9KK5 + the .p8. (me) wires upload/automation (COM-01).
10. ASC → Monetization → In-App Purchases: create non-consumable
    **com.getpocketai.app.pro** (COM-02). Enroll in the **Small Business
    Program** (15% not 30%).
11. (me) TestFlight build via the ASC API key (archive + upload). Internal →
    ~50 external testers.
12. (me) Submit for review — App Review notes + review-friendly model ready
    (docs/app-review-notes.md, catalog Qwen3-0.6B-4bit).

## Waitlist (WEB-02 — your call)
Pick one: a `mailto:` "Get notified" link, an App Store pre-order link, or a
third-party form (Buttondown/ConvertKit — a third party). (me) wire the choice.

## The two channels
- Direct (site → Stripe → Keygen key): ~3% fee, works iPhone + Mac. Best margin.
- App Store IAP (com.getpocketai.app.pro): 15% (SBP). Required on iOS.
Same Pro unlock either way (merged offline by LIC-03).
