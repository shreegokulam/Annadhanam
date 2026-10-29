# Annadhanam Booking — Dubai Ayyappa Samaj (setup: about 15 minutes, all free)

Themed on the 55th Year Mandala Masa Celebrations invitation. Event: Annadhanam, Sunday 20 December 2026, Winners Club, Ajman. The event date is already set to 2026-12-20; the venue and organisation names are in the CONFIG block of `index.html`.

Files: `index.html` (the whole app) and `schema.sql` (the database).

## 1. Try it first (demo mode)
Open `index.html` as it is (or host it, step 3). With no Supabase details it runs in **demo mode**: data stays in that browser only. Demo PINs: staff `1234`, admin `9999`.
Camera scanning needs HTTPS, so test the scanner after hosting it.

## 2. Create the database (Supabase free plan)
1. supabase.com > New project (any region near your guests).
2. SQL Editor > New query > paste all of `schema.sql` > Run.
3. Project Settings > API: copy the **Project URL** and the **anon / publishable key**.
4. In `index.html`, fill in the CONFIG block near the top:
   ```js
   SUPABASE_URL: 'https://xxxx.supabase.co',
   SUPABASE_KEY: 'your-anon-or-publishable-key',
   ```
   The anon key is safe to publish: the tables are locked and everything goes through PIN-protected functions.

## 3. Host it (free)
Drag the folder with `index.html` onto **app.netlify.com/drop**, or use GitHub Pages or Cloudflare Pages. You get an https link.

| Who | Link |
|---|---|
| Guests | `https://your-site/` |
| Entrance volunteers | `https://your-site/#/scan` |
| You | `https://your-site/#/admin` |

## 4. Before the event
1. Open `/#/admin` (default admin PIN `654321`) > **Settings**: set the event title, **event date**, per-slot cap and **change both PINs** (default staff PIN is `123456`).
2. Make a test booking and scan it with a volunteer phone.
3. Share the guest link in your WhatsApp groups. Because there is no SMS, tell guests to **save the ticket image**.

## 5. Event day
- Each volunteer opens the scanner link, enters the staff PIN and allows the camera. Put the phone on the home screen for quick access.
- Scan: **green** = admit (big number is how many people), **red** = already used or invalid, **amber** = wrong time (admit anyway is one tap).
- Run 4–6 scanning phones, plus one "Search" desk for lost tickets (search by phone, name or code) and walk-ins.
- If the internet drops, scanners keep working from their saved list and sync later. Open the scanner once on Wi-Fi/data at the venue before guests arrive so the list is saved.

## Capacity note
250 per slot × 6 slots = **1,500 people**. For 2,000, set the cap to about **340** in Admin > Settings.

## Good to know
- Max 4 people per booking and 2 bookings per phone number (changeable in Settings).
- Guests cannot see each other's details. Names and phones are visible only to staff and admin PINs.
- Free Supabase plan is plenty for 2,000 bookings. Scanner phones refresh their list about once a minute.
