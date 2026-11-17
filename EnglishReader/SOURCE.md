# Bundled content and sources

## Reading sample

**Work:** *Alice’s Adventures in Wonderland*, Lewis Carroll (Charles Lutwidge Dodgson), first published in 1865.

**Source:** Project Gutenberg eBook #11: https://www.gutenberg.org/ebooks/11

**Source text:** https://www.gutenberg.org/ebooks/11.txt.utf-8

**Scope:** Short opening excerpts of Chapters I, II and III only. The app explicitly labels this as “Excerpts”; it is not the complete novel. The bundled text is in `SampleBook.swift`. Chapter numbering/punctuation and paragraph layout are normalized for the reader; emphasis is represented with `<em>` tags. The beginning of Chapter II’s verse address is formatted with line breaks. No illustrations or modern editorial material are included.

**Rights:** The underlying 1865 English text is public domain in the United States. Users outside the United States should check the law in their jurisdiction. This is a public-domain excerpt, not an endorsement by or an official edition of Project Gutenberg. The Project Gutenberg source edition’s distribution terms and trademark notice are available at https://www.gutenberg.org/policy/license.html and in the linked source text. This record identifies provenance; no rights in the underlying public-domain work are claimed.

The sample is bundled in the application; importing and reading do not make network requests. URLs above are provenance records, not remote dependencies.

## Test-only compatibility fixture

`EnglishReaderTests/Fixtures/alice.epub` is a complete Project Gutenberg #11 EPUB, downloaded from https://www.gutenberg.org/ebooks/11.epub3.images on 2026-11-06 to exercise real-world EPUB parsing. It is included only in the test target, not the shipped app. The source EPUB retains its own license/trademark notices.

## Offline English–Chinese dictionary

`EnglishReader/Resources/dictionary-core.sqlite` (the core pack) is built from **ECDICT** by Linwei (skywind3000): https://github.com/skywind3000/ECDICT (`ecdict.csv` at commit `9c46923fb81a2eb6c264a3a1689562ea7bc56b6a`; the URL and sha256 are pinned in `Dictionaries/release.json`).

`Tools/build-dictionary.py` splits ECDICT into packs that combine as a union: the bundled core (common single words — exam-tagged, Collins/Oxford-marked, or within the top 60,000 by BNC/frequency rank — their inflections, and general phrases made of common words), plus downloadable packs for the remaining general vocabulary, eight subject fields (by ECDICT's “[医]”-style labels) and names. Each entry keeps its full Chinese translation, English definition, exam tags, Collins stars, Oxford 3000 mark and inflections; the core also carries the inflection-to-base-word table. The app reads packs locally; the core never needs the network. The other packs are published as release assets of this repository and listed in `Dictionaries/manifest.json`; the app fetches that list and downloads a pack only from Settings › 词典. The license is credited in the app's 设置 › 关于.

ECDICT license:

```
MIT License

Copyright (c) 2025 Linwei

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
