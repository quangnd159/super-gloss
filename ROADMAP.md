# Roadmap

Super Gloss stays minimal and should just work. Each item below has to fit that.

## Next

1. **Navigation polish.** ⌘← / ⌘→ and trackpad swipe for back and forward (a mouse's side buttons already work); Space / ⇧Space to page through results from the search line.
2. **Lemmatizers beyond English** (French, German, Spanish, …), so "ran → run"-style matching works in every language.
3. **UI tests.** Automated tests for the hotkey and focus behavior. (The universal build and the signed, notarized DMG shipped in 1.0.0.)

## Shipped in 1.3.2

- **Update checks that get through.** Check for Updates no longer fails with "GitHub answered 403" when other apps on your network have been asking GitHub too.
- **Plain messages.** When a check or download does go wrong, the message says so in plain words, and if an update can't be put in place, Super Gloss offers to download it instead.

## Shipped in 1.3.1

- **One card per paste.** Copy in the share menu now gives one image: pasting a copied card into a browser, say a Facebook post, used to attach it three times.

## Shipped in 1.3.0

- **Share as Image.** Select a passage in an entry and press `⇧⌘I`, or right-click it: Super Gloss sets it on a card under the word, marked where it stands in its dictionary's own typesetting, and hands the image to the system's share menu. One size (1080 × 1350), text only, in the app's light or dark.

## Shipped in 1.2.3

- **One column at every size.** The margin list from 1.2.0 is gone: entries sit in one centred column under a pinned dictionary name, and the books button on the search line (or `⌘J`) goes to any of them.
- **Mac keys.** ↑ / ↓ scroll the page after a lookup; ⌥⌘↑ / ⌥⌘↓ step between dictionaries, and ⌥⌘← / ⌥⌘→ hide or show one.
- **Mouse parity.** A clear button, right-click Look Up, side buttons for back and forward, the wheel along the related words, and context menus on saved and recent words.
- **Smarter search.** Common words for one- and two-letter searches, swapped letters as one typo, fast wildcards.
- **Sturdier core.** Damaged dictionaries and indexes fail alone and rebuild instead of crashing.

## Shipped in 1.2.0

- **A new reading page.** Each entry opens with its dictionary's name. The margin lists every dictionary that answered and marks the one you're reading; click a name to go there.
- **Go to a dictionary (⌘J).** Type a few letters to narrow the list, Return to go there, Esc to go back.
- **Arrows for dictionaries.** ↑ / ↓ step between dictionaries wherever you are; ⌥↑ / ⌥↓ move along the related words.
- **Updates on their own.** New versions download in the background and go in on relaunch, coming back to the same word.
- **Icons optional.** Settings can hide dictionaries' icons.

## Shipped in 1.1.0

- **Saved words.** ⌘D saves the word you are reading. Saved words sit above Recent on the home page. No account, no sync.
- **Find in entries.** ⌘F searches every open entry at once.
- **Links.** Cross-references land on the right sense, and Back and Forward return to where you were reading.
- **Better surprises.** Surprise Me favors words your dictionaries agree on and skips noise, inflections, repeats and slurs.
