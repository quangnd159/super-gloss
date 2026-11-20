# Roadmap

Super Gloss stays minimal and should just work. Each item below has to fit that.

## Next

1. **Look up in place.** Select a word in any app, press the hotkey, and a small floating card answers right there without switching apps. This is the biggest upgrade.
2. **Navigation polish.** ⌘← / ⌘→ and trackpad swipe for back and forward; Space / ⇧Space to page through results.
3. **Search inside definitions.** For example, "words meaning *short-lived*" should find ephemeral, transient and fleeting. A full-text index alongside the headword FST.
4. **Lemmatizers beyond English** (French, German, Spanish, …), so "ran → run"-style matching works in every language.
5. **UI tests.** Automated tests for the hotkey and focus behavior. (The universal build and the signed, notarized DMG shipped in 1.0.0.)

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
