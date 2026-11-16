# Builds EnglishReader/Resources/dictionary.sqlite from ECDICT (https://github.com/skywind3000/ECDICT).
# Usage: python3 -I Tools/build-dictionary.py path/to/ecdict.csv EnglishReader/Resources/dictionary.sqlite
import csv, sqlite3, sys, re, os
src, out = sys.argv[1], sys.argv[2]
csv.field_size_limit(10**8)
WORD = re.compile(r"^[A-Za-z]+(?:['’-][A-Za-z]+)*$")
rows = {}
forms = {}
def clean(t):
    lines = [l.strip() for l in t.replace('\\n', '\n').split('\n') if l.strip()]
    main = [l for l in lines if not l.startswith('[网络]')]
    lines = main or lines
    return '\n'.join(lines[:4])[:300]
with open(src, encoding='utf-8') as f:
    for r in csv.DictReader(f):
        w = r['word'].strip()
        if not WORD.match(w) or not r['translation'].strip(): continue
        bnc = int(r['bnc'] or 0); frq = int(r['frq'] or 0)
        common = r['tag'].strip() or r['collins'].strip() or r['oxford'].strip() or 0 < bnc <= 60000 or 0 < frq <= 60000
        ex = dict(p.split(':', 1) for p in r['exchange'].split('/') if ':' in p)
        lemma = ex.get('0', '')
        if not common and not lemma: continue
        key = w.lower()
        rank = min([x for x in (bnc, frq) if x > 0] or [10**7])
        pref = (w != key, rank)
        if key in rows and (rows[key][1] != key, rows[key][4]) <= pref: continue
        rows[key] = (key, w, r['phonetic'].strip(), clean(r['translation']), rank, lemma.lower())
        for k in 'pdi3rts':
            for form in ex.get(k, '').split(','):
                form = form.strip().lower()
                if form and form != key: forms.setdefault(form, key)
if os.path.exists(out): os.remove(out)
db = sqlite3.connect(out)
db.execute('CREATE TABLE entry(key TEXT PRIMARY KEY, word TEXT, phonetic TEXT, translation TEXT, rank INTEGER, lemma TEXT) WITHOUT ROWID')
db.execute('CREATE TABLE form(form TEXT PRIMARY KEY, lemma TEXT) WITHOUT ROWID')
db.executemany('INSERT INTO entry VALUES (?,?,?,?,?,?)', rows.values())
db.executemany('INSERT INTO form VALUES (?,?)', [(f, l) for f, l in forms.items() if l in rows])
db.commit(); db.execute('VACUUM'); db.close()
print(len(rows), 'entries', len(forms), 'forms', os.path.getsize(out) // 1024, 'KB')
