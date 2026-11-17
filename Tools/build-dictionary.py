# Builds the dictionary packs from ECDICT (https://github.com/skywind3000/ECDICT).
# Usage: python3 -I Tools/build-dictionary.py path/to/ecdict.csv OUT_DIR [pack ...]
#
# Every ECDICT entry goes to exactly one pack, so packs combine as a union:
#   core         common words, their inflections and general phrases (bundled with the app)
#   extended     the remaining general words and phrases
#   medicine, chemistry, computing, economics, law, electronics, mechanics, sciences
#                entries whose every sense carries that field's label, e.g. "[医]"
#   names        capitalized words and phrases: people, places, organizations, taxa
# An entry labelled for two fields goes to both field packs; the app de-duplicates by key.
# Only core carries the `form` table (inflection -> base word), so the key a saved word
# gets never depends on which packs are installed.
# Writes OUT_DIR/dictionary-<pack>.sqlite; with no pack names, writes all of them.
import csv, os, re, sqlite3, sys, unicodedata

SCHEMA = 2
SOURCE_DATE = "2026-11-17"
PACKS = {  # id: (title, order)
    "core": ("核心词典", 0), "extended": ("扩展词汇", 10),
    "medicine": ("医学", 20), "chemistry": ("化学", 21), "computing": ("计算机", 22), "economics": ("经济", 23),
    "law": ("法律", 24), "electronics": ("电子电气", 25), "mechanics": ("机械工程", 26), "sciences": ("其他学科", 27),
    "names": ("人名地名", 30),
}
FIELDS = {
    "医": "medicine", "药": "medicine", "解": "medicine", "生化": "medicine",
    "化": "chemistry", "计": "computing", "经": "economics", "商": "economics", "法": "law", "律": "law",
    "电": "electronics", "机": "mechanics",
}
SCIENCES = "建 植 动 生 矿 地 物 数 天 微 气 农 军 海 航 核 冶 纺 船 测 印 林 心 环".split()
FIELD_LABEL = re.compile(r"\[(" + "|".join(sorted(list(FIELDS) + SCIENCES, key=len, reverse=True)) + r")\]")
WORD = re.compile(r"^[a-z]+(?:['-][a-z]+)*$")
PHRASE = re.compile(r"^[a-z][a-z'. -]*$")
PHRASE_FILLERS = {"sb", "sth", "sb's", "sth's", "one's", "oneself", "someone", "something", "somebody", "a", "an", "the"}
FORM_KINDS = "pdi3rst"  # past, past participle, -ing, third person, comparative, superlative, plural
IRREGULAR = {"am": "be", "are": "be", "was": "be", "were": "be"}  # ECDICT lists none of these under "be"
INFLECTION_NOTE = r"的[^\n()（）;；]*?(过去式|过去分词|现在分词|第三人称单数|复数|比较级|最高级)"


def mentions_base(translation, base):
    """True for "be的过去式", "v. 做（do的第三人称单数形式）" and the like."""
    return re.search(re.escape(base) + r"\s*" + INFLECTION_NOTE, translation, re.IGNORECASE) is not None


def normalize(text):
    """Same as WordDictionary.normalize in the app: lookups use these keys."""
    keep = {"'", "’", "-"}
    def strip(c): return c.isspace() or (unicodedata.category(c).startswith("P") and c not in keep)
    start, end = 0, len(text)
    while start < end and strip(text[start]): start += 1
    while end > start and strip(text[end - 1]): end -= 1
    return " ".join(text[start:end].replace("’", "'").split()).lower()


POS = re.compile(r"^(n|v|vt|vi|a|adj|s|r|adv|prep|conj|pron|int|interj|num|art|abbr|pl|aux)\.?\s+")


def lines(text):
    return "\n".join(line.strip() for line in text.replace("\\n", "\n").split("\n") if line.strip())


def english_senses(text):
    """English definitions, one sense per line: hard-wrapped continuation lines (Webster's) join their
    sense, and "n the part" becomes "n. the part"."""
    result = []
    for line in lines(text).split("\n"):
        match = POS.match(line)
        if match or not result:
            result.append(POS.sub(lambda m: m.group(1) + ". ", line, count=1) if match else line)
        else:
            result[-1] += " " + line
    return "\n".join(result)


def main():
    src, out_dir, wanted = sys.argv[1], sys.argv[2], set(sys.argv[3:]) or set(PACKS)
    csv.field_size_limit(10**8)
    rows = {}
    with open(src, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            word, translation = r["word"].strip(), lines(r["translation"])
            key = normalize(word)
            if not translation or not key or len(key) > 64: continue
            bnc, frq = int(r["bnc"] or 0), int(r["frq"] or 0)
            rank = min([x for x in (bnc, frq) if x > 0] or [10**7])
            exchange = dict(p.split(":", 1) for p in r["exchange"].split("/") if ":" in p)
            row = dict(key=key, word=word, phonetic=r["phonetic"].strip(), translation=translation,
                       definition=english_senses(r["definition"]), tags=" ".join(r["tag"].split()),
                       collins=int(r["collins"] or 0), oxford=int(r["oxford"] or 0), rank=rank,
                       exchange=exchange, common=bool(r["tag"].strip() or r["collins"].strip() or r["oxford"].strip()
                                                       or 0 < bnc <= 60000 or 0 < frq <= 60000))
            # One entry per key: lowercase spellings first, then the more frequent.
            old = rows.get(key)
            if old is None or (word != key, rank) < (old["word"] != old["key"], old["rank"]):
                rows[key] = row

    common_words = {k for k, r in rows.items() if WORD.match(k) and r["common"]}
    packs = {p: [] for p in PACKS}
    for key, r in rows.items():
        if not (WORD.match(key) or PHRASE.match(key)): continue
        is_phrase = " " in key
        lemma = normalize(r["exchange"].get("0", ""))
        # A field pack only takes entries whose every sense is labelled for a field:
        # "give up" also has a "[法]" sense but belongs with the general phrases.
        senses = [line for line in r["translation"].split("\n") if not line.startswith("[网络]")]
        labels = [FIELD_LABEL.findall(line) for line in senses]
        fields = {FIELDS.get(m, "sciences") for found in labels for m in found} if senses and all(labels) else set()
        capitalized = r["word"][:1].isupper()
        if not is_phrase and (r["common"] or (lemma and lemma in common_words)):
            packs["core"].append(r)
        elif is_phrase and not fields and not capitalized and all(
                w.strip("'.-") in common_words or w in PHRASE_FILLERS for w in key.split()):
            packs["core"].append(r)
        elif fields:
            for field in fields: packs[field].append(r)
        elif capitalized:
            packs["names"].append(r)
        else:
            packs["extended"].append(r)

    # Inflection -> base word. A form redirects to a base that lists it when the form has no entry
    # of its own, or its entry points back at that base ("0:" in its exchange, or a note such as
    # "go的过去式"). Among several bases the more frequent wins: "does" is "do", not "doe".
    # "left" redirects to "leave" too; the app still shows what "left" means on its own.
    candidates = {}
    def offer(form, lemma):
        if form and lemma and form != lemma and lemma in rows:
            candidates.setdefault(form, set()).add(lemma)
    for key, r in rows.items():
        if " " in key: continue
        for kind in FORM_KINDS:
            for form in r["exchange"].get(kind, "").split(","):
                form = normalize(form)
                own = rows.get(form)
                if own is None or normalize(own["exchange"].get("0", "")) == key or mentions_base(own["translation"], r["word"]):
                    offer(form, key)
        offer(key, normalize(r["exchange"].get("0", "")))
    for form, lemma in IRREGULAR.items(): offer(form, lemma)
    forms = {form: min(lemmas, key=lambda l: (rows[l]["rank"], l)) for form, lemmas in candidates.items()}

    os.makedirs(out_dir, exist_ok=True)
    for pack in sorted(wanted):
        title, order = PACKS[pack]
        path = os.path.join(out_dir, f"dictionary-{pack}.sqlite")
        if os.path.exists(path): os.remove(path)
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID")
        db.execute("""CREATE TABLE entry(key TEXT PRIMARY KEY, word TEXT, phonetic TEXT, translation TEXT,
                      definition TEXT, tags TEXT, collins INTEGER, oxford INTEGER, rank INTEGER, forms TEXT) WITHOUT ROWID""")
        entries = packs[pack]
        db.executemany("INSERT INTO entry VALUES (?,?,?,?,?,?,?,?,?,?)", [
            (r["key"], r["word"], r["phonetic"], r["translation"], r["definition"], r["tags"], r["collins"], r["oxford"],
             r["rank"], "/".join(f"{k}:{r['exchange'][k]}" for k in FORM_KINDS if r["exchange"].get(k)))
            for r in entries])
        if pack == "core":
            db.execute("CREATE TABLE form(form TEXT PRIMARY KEY, lemma TEXT) WITHOUT ROWID")
            db.executemany("INSERT INTO form VALUES (?,?)", list(forms.items()))
        db.executemany("INSERT INTO meta VALUES (?,?)", [
            ("schema", str(SCHEMA)), ("id", pack), ("title", title), ("order", str(order)),
            ("source", "ECDICT"), ("sourceDate", SOURCE_DATE), ("entries", str(len(entries)))])
        db.commit(); db.execute("VACUUM"); db.close()
        print(f"{pack:12} {len(entries):8} entries {os.path.getsize(path) // 1024:8} KB")
    print(f"{'forms':12} {len(forms):8}")


if __name__ == "__main__":
    main()
