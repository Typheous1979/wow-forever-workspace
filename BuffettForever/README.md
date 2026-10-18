# BuffettForever

*by Typheous*

An Auction House scanner and crafting advisor for World of Warcraft: Forever: what to craft, where to sell it,
and the return on every gold piece. Named for Warren Buffett's rules of investing (no affiliation): never lose
money, keep a margin of safety, let Mr. Market's moods serve you, and count what you give up.

- **Auction House prices**: a full scan (the **Scan** button in the window or under the Auction House frame)
  prices every listing in about 5 seconds; the Auction House allows one about every 15 minutes. Prices keep
  14 days of history, so one odd scan doesn't fool you. Item tooltips show the market value, the cheapest listing,
  and what a vendor pays and charges. **Alt+Right-click** an item in your bags to price-check it at the Auction
  House. Your own auctions are left out of the prices.
- **Reagent tray**: drop up to 25 materials into the tray (drag them, Alt+Right-click them, or **Load from bags**)
  to see every recipe that uses them, from every profession. The ones your characters know are marked. Each slot
  shows where its units are: an envelope for what's still in your mailbox, a grey icon when none are in your bags,
  and an orange count when the tray counts more than you have.
- **Four views**, from the tabs under the window:
  - **Tray**: the recipes your tray's reagents make;
  - **Vendor crafts**: recipes you know that profit on vendor prices alone, with no Auction House risk;
  - **AH flips**: listings in your last scan priced below what a vendor pays;
  - **Profession profits**: every recipe in your professions, in a group per profession with your skill. Only the
    tray's materials count as yours; everything else is priced to buy, even what's in your bags or bank.

  The **search box** above the list finds items by name as you type, in every view. The * of a recipe you know
  takes its skill-up colour, as in the profession window.
- **Every recipe in full**, laid out like the profession window:
  - the reagents, from a vendor, the Auction House, a recipe you know, or your bags at what they'd sell for;
  - the vendor and Auction House exits, after the house cut, the deposit and the chance it sells;
  - profit, ROI, a confidence grade (A to D) and the best batch size.

  A top pick names the best return and where to sell it.
- **Buying, one click at a time**, from the Buy bar under the details (Profession profits and AH flips):
  - in Profession profits, **Crafts** sets the batch, and **Best** picks the best batch your gold covers;
  - at the Auction House, **Buy** shows a missing reagent's live price, and **Confirm** buys it at that price or
    less. A rise over the estimate shows, and a loss shows in red;
  - at a vendor, Buy buys the reagents it sells, straight into your bags;
  - on AH flips, Buy buys what's still below what a vendor pays: a stackable item in one purchase, gear one auction
    at a time.

  What you buy for a recipe goes into the tray. Auction House purchases come by mail: the tray marks them with an
  envelope until you collect them, and **Collect**, a button under the mail window, takes them, one mail per click.
- **Crafting and selling**, from the second row under the details (every recipe view, for recipes you know):
  - **Create** crafts the Crafts box's number from your bags. The game crafts only with the profession's window
    open, so the first click, **Open Profession**, opens it at the recipe. During a batch the button is Stop. Every
    finished craft, from either window, takes its reagents off the tray.
  - **Sell on AH**, at the Auction House, lists what you crafted that's still in your bags at the cheapest listing
    by others, from a search just before. The price, the deposit and what you'd get show first, and **Confirm**
    posts. It refuses a price a vendor beats. An expired or cancelled auction is yours to sell again once you take
    it from the mail.
- **Your sales**: BuffettForever reads the Auction House mail in your mailbox (sold, expired, cancelled) without
  opening it. Your sales measure the house cut and each item's chance to sell; `/bf ledger` sums them up.
- **Market sense**: a price that holds for days while nothing sells is flagged, a price well away from its fair
  value shows as cheap or dear (Mr. Market), and the best batch respects how much the market can take.
- **Settings** (the **Options** tab, or Options › AddOns › BuffettForever):
  - when to recommend: margin of safety, minimum profit per craft, the lowest confidence grade;
  - how to count: your own materials, the house cut, the sale chance;
  - selling on the Auction House: the price Sell on AH posts at (the cheapest listing, or 1c, 1%, 5% or 10% under
    it; gear in whole silver), the auction length, and never below what a vendor pays;
  - how many days of prices to keep.
- **It never buys or posts without your click:** each shows its price first.

## Commands
`/bf` (or `/buffett`) opens the window. `/bf help` lists the rest: `scan`, `options`, `ledger`,
`recipes <item>`, `minimap`, and `eval`, `diag` and `selftest` for checking the numbers.

## How it works
Prices come from the Auction House API while you're at an auctioneer. The 1,976 recipes come from Forever's own
game tables, and vendor prices from the item data and the merchants you visit. Deposits follow Forever's
formula: 5% of the vendor price per 2 hours (8 hours x4, 24 hours x12), at least 1s per auction.

SavedVariables: `BuffettForeverDB` (prices, your sales and the settings, shared by your characters) and
`BuffettForeverCharDB` (the window, the tray, your purchases still in the mail, and what you crafted until you sell
it, per character).
