import json,re,os
OUT='/tmp/rights/out2'; os.makedirs(OUT,exist_ok=True)
for f in os.listdir(OUT): os.remove(os.path.join(OUT,f))
# territory → our country labels and schedule codes (only where the territory is one country or a stated region)
T={"Albania":"ألبانيا","Austria":"النمسا","Belgium":"بلجيكا","Bosnia and Herzegovina":"البوسنة","Bulgaria":"بلغاريا","Croatia":"كرواتيا","Cyprus":"قبرص",
"Czechia":"التشيك","Czech Republic":"التشيك","Denmark":"الدنمارك","Finland":"فنلندا","France":"فرنسا","Germany":"ألمانيا","Greece":"اليونان","Hungary":"المجر",
"Italy":"إيطاليا","Netherlands":"هولندا","North Macedonia":"مقدونيا الشمالية","Norway":"النرويج","Poland":"بولندا","Portugal":"البرتغال",
"Republic of Ireland":"إيرلندا","Republic of Ireland (Eire)":"إيرلندا","Ireland":"إيرلندا","Romania":"رومانيا","Russia":"روسيا","Serbia":"صربيا","Slovakia":"سلوفاكيا",
"Slovenia":"سلوفينيا","Spain":"إسبانيا","Sweden":"السويد","Switzerland":"سويسرا","Türkiye":"تركيا","Turkey":"تركيا","Ukraine":"أوكرانيا",
"United Kingdom":"بريطانيا","Canada":"كندا","Mexico":"المكسيك","Brazil":"البرازيل","Argentina":"الأرجنتين","United States of America":"أمريكا","United States":"أمريكا",
"Australia":"أستراليا","New Zealand":"نيوزيلندا","South Africa":"جنوب أفريقيا","Malaysia":"ماليزيا","Indonesia":"إندونيسيا","Singapore":"سنغافورة","Pakistan":"باكستان",
"Middle East/North Africa":"عربي","MENA":"عربي","Middle East and North Africa":"عربي"}
# holder → channel brands as channel lists write them (our mapping, marked as such), and what kind of entity it is
BR={"telefonica":["Movistar"],"cyta":["Cytavision"],"cytavision":["Cytavision"],"sky deutschland":["Sky"],"sky italia":["Sky"],"sky austria":["Sky"],"sky":["Sky"],
"sky sports":["Sky"],"sky nz":["Sky"],"tnt sports":["TNT"],"bein":["beIN"],"bein sports":["beIN"],"canal+":["Canal+"],"ziggo sport":["Ziggo Sport"],"dazn":["DAZN"],
"viaplay":["Viaplay"],"supersport":["SuperSport"],"espn":["ESPN"],"arena sport":["Arena Sport"],"sport tv":["Sport TV"],"setanta":["Setanta"],"premier sports":["Premier Sports"],
"paramount+":["Paramount+"],"nbc sports":["NBC"],"digi":["Digi Sport"],"polsat":["Polsat"],"tudn":["TUDN"],"stan sport":["Stan Sport"],"sony":["Sony"],
"img (sublicensed to nova broadcasting group)":["Nova Sport"],"img (sublicensed to nova)":["Nova Sport"],"novasports":["Nova Sport"],"fox":["Fox Sports"],"fox broadcasting corporation":["Fox Sports"],
"tnt sports mexico":["TNT"],"amazon prime":["Prime Video"],"fubo":["Fubo"]}
ENT={"telefonica":"company","saran media":"company","img":"company","jasmine international / mono":"company","emtek":"company","astro":"company","pccw":"company",
"starhub":"company","jiostar":"company","dpg media":"company","proximus":"company","telenet":"company","cyta":"company","cytavision":"company","digicel":"company",
"quest media":"company","fox broadcasting corporation":"company","dazn":"platform","paramount+":"platform","amazon prime":"platform","stan sport":"platform","viaplay":"platform",
"max":"platform","disney+":"platform","fubo":"platform","iqiyi":"platform","migu":"platform","okko":"platform","megogo":"platform","u-next":"platform","coupang":"platform",
"lemino":"platform","tapmad":"platform","fpt play":"platform","magentatv platform":"platform","magenta tv platform":"platform"}
def holder(raw, rights):
    m=re.match(r'^(.*?)\s*\((?:sublicensed to)\s*([^)]*)\)\s*$',raw)
    sub=None; name=raw
    if m: name=m.group(1).strip(); sub=m.group(2).strip()
    k=raw.lower().strip(); kn=name.lower().strip()
    h={"name":name,"entity":ENT.get(kn,"unknown"),"rights":rights,"channels":[]}
    b=BR.get(k) or BR.get(kn)
    if b: h["brands"]=b; h["brandsFrom"]="shasha"   # our mapping from the holder to the channel names in IPTV lists
    if sub: h["sublicence"]=sub
    return h
def file(slug, comp, keys, excludes, season, source, territories, window=None):
    y=int(season[:4]) if season[:4].isdigit() else None
    d={"format":"shasha-rights","version":2,"competition":{"name":comp,"keys":keys,"excludes":excludes},"season":season,"source":source,"territories":territories}
    if y: d["technicalWindow"]={"from":f"{y}-07-01","to":f"{y+1}-06-30","note":"نافذة تقنية مشتقة من اسم الموسم — ليست تواريخ عقد، ولا تُحذف البيانات بسببها"}
    json.dump(d,open(f"{OUT}/{slug}.json","w",encoding="utf-8"),ensure_ascii=False,indent=1)
    print(slug,len(territories))
def terr(name, holders, region=None, status="verified", source=None, contract=None, note=None):
    t={"territory":name,"region":region,"countries":[T[name]] if name in T else [],"status":status,"holders":holders}
    if source: t["source"]=source
    if contract: t["contract"]=contract
    if note: t["note"]=note
    return t
EXC_UEFA=["women","womens","youth","u19","u-19","futsal","سيدات","للشباب"]
def uefa(md, slug, comp, keys):
    lines=open(md,encoding='utf-8').read().splitlines()
    meta={l.split(':',1)[0]:l.split(':',1)[1].strip() for l in lines[:5] if ':' in l}
    src={"url":meta['SOURCE'],"title":meta['TITLE'],"publisher":"UEFA","kind":"official","retrievedAt":meta['RETRIEVED']}
    ts=[];region=None
    for l in lines[5:]:
        if l.startswith('###'): region=l.strip('# ').strip(); continue
        if ':' not in l: continue
        t,h=l.split(':',1); hs=[]
        for x in re.split(r',(?![^(]*\))',h):
            x=x.strip()
            if not x: continue
            hs.append(holder(x.rstrip('*').strip(), ["highlights"] if x.endswith('*') else ["live"]))
        ts.append(terr(t.strip(),hs,region))
    file(slug,comp,keys,EXC_UEFA,meta['SEASON'],src,ts)
uefa('/tmp/rights/ucl-2026-27.md','uefa-champions-league-2026-27','UEFA Champions League',["uefa champions league","champions league","دوري أبطال أوروبا","دوري ابطال اوروبا"])
uefa('/tmp/rights/uel-2026-27.md','uefa-europa-league-2026-27','UEFA Europa League',["uefa europa league","europa league","الدوري الأوروبي","الدوري الاوروبي"])
# ---- Premier League (official list, contracts stated)
lines=open('/tmp/rights/pl-2025-28.md',encoding='utf-8').read().splitlines()
meta={l.split(':',1)[0]:l.split(':',1)[1].strip() for l in lines[:5] if ':' in l}
plsrc={"url":meta['SOURCE'],"title":meta['TITLE'],"publisher":"Premier League","kind":"official","retrievedAt":meta['RETRIEVED']}
ts=[];region=None
for l in lines[5:]:
    if l.startswith('###'): region=l.strip('# ').strip(); continue
    if ' - ' not in l: continue
    t,h=l.split(' - ',1); stars=len(h)-len(h.rstrip('*')); h=h.rstrip('*').strip()
    contract={0:"2025/26–2027/28",1:"2025/26–2030/31",2:"2025/26–2028/29",3:"2026–2030/31 (من 1 يناير 2026)"}[stars]
    hs=[];hl=None
    m=re.search(r'\(highlights - ([^)]*)\)',h)
    if m: hl=m.group(1); h=h[:m.start()].strip()
    for x in re.split(r',(?![^(]*\))',h):
        x=x.strip()
        if not x: continue
        note=None
        lm=re.match(r'^(.*?)\s*\((French|German|Italian)(?:-language)?\)$',x)
        if lm: x=lm.group(1); note={"French":"باللغة الفرنسية","German":"بالألمانية","Italian":"بالإيطالية"}[lm.group(2)]
        for y in (re.split(r'(?<=\S)/(?=\S)',x)):
            hh=holder(y.strip(),["live"])
            if note: hh["note"]=note
            hs.append(hh)
    if hl: hs.append(holder(hl,["highlights"]))
    ts.append(terr(t.strip(),hs,region,contract=contract))
file('premier-league-2026-27','Premier League',["premier league","english premier league","الدوري الإنجليزي الممتاز","الدوري الانجليزي الممتاز"],
     ["egypt","egyptian","kuwait","bahrain","qatar","scottish","welsh","northern","irish","ukrainian","russian","israeli","maltese","armenian","kazakh","bangladesh",
      "ghana","nigeria","kenya","south","hong","premier league 2","u21","u18","women","womens","sudan","lebanese","jordan","iraq","syrian","palestinian","tanzania",
      "uganda","zambia","ethiopia","rwanda","malawi","libyan","omani","emirati","saudi","singapore","papua","kenyan","ghanaian","nigerian","ugandan",
      "tanzanian","zambian","ethiopian","rwandan","malawian","sudanese","bahraini","kuwaiti","qatari","jordanian","iraqi","libya","oman","uae","kenya"],"2026/27",plsrc,ts)
# ---- Cyta (Cyprus) per competition, official holder page, selected matches, season not stated
cy={"url":"https://www.cyta.com.cy/cytavision-sports-content/en","title":"Cytavision Sports content (cyta.com.cy)","publisher":"Cyta","kind":"official","retrievedAt":"2026-11-24"}
def cyt(r4k=False, via=None):
    h=holder("Cytavision",["live","selected"]); h["entity"]="company"
    h["note"]="الصفحة: البث المباشر يشمل مباريات مختارة" + (" · 4K متاح (ExperienceMore)" if r4k else "") + (f" · عبر باقة {via}" if via else "")
    return h
CYP=lambda r4k=False,via=None: terr("Cyprus",[cyt(r4k,via)],"Europe",source=cy,note="الصفحة لا تذكر الموسم؛ كما هي في 2026-11-24")
# ---- Serie A: per country, each record with its own announcement
SA_EXC=["coppa","supercoppa","brazil","brasileiro","brasileirao","ecuador","femminile","women","womens","primavera","serie a2","futsal"]
dazn_uk={"url":"https://dazngroup.com/press-room/dazn-renews-serie-a-rights-in-the-uk-ireland-for-the-2026-27-season/","title":"DAZN Renews Serie A Rights in the UK & Ireland for the 2026-27 Season (DAZN, 20 Aug 2026)","publisher":"DAZN","kind":"official","retrievedAt":"2026-11-24"}
par={"url":"https://www.paramountpressexpress.com/paramount-plus/releases/?view=112947-cbs-sports-and-lega-serie-a-extend-us-media-rights-partnership-through-20262027-season-with-all-matches-to-continue-to-be-streamed-on-paramount","title":"CBS Sports and Lega Serie A Extend U.S. Media Rights Partnership Through 2026/2027 Season (Paramount, 4 Jun 2026)","publisher":"Paramount","kind":"official","retrievedAt":"2026-11-24"}
tnt={"url":"https://www.sportcal.com/media/serie-a-extends-with-tnt-sports-in-uk-through-2026-27/","title":"Serie A extends with TNT Sports in UK through 2026-27 (SportBusiness/Sportcal)","publisher":"Sportcal","kind":"secondary","retrievedAt":"2026-11-24"}
def dz(note,rights=["live"]): h=holder("DAZN",rights); h["note"]=note; return h
ukh=[dz("كل المباريات، سبع منها حصرية كل جولة"), dict(holder("TNT Sports",["live"]),note="من مصدر ثانوي (Sportcal) — بلا إعلان رسمي وجدناه")]
sa=[terr("United Kingdom",ukh,"Europe",source=dazn_uk,contract="2026/27"),
    terr("Republic of Ireland",[dz("كل المباريات، سبع منها حصرية كل جولة")],"Europe",source=dazn_uk,contract="2026/27"),
    *[terr(c,[dz("حصري، كل المباريات")],"Europe",source=dazn_uk,contract="حتى نهاية 2028/29") for c in ["France","Germany","Austria","Switzerland"]],
    terr("United States of America",[dict(holder("Paramount+",["live","digital"]),note="كل المباريات بثًا عبر Paramount+ (CBS Sports)")],"Americas",source=par,contract="حتى 2026/27"),
    CYP()]
ISO={"ar":"عربي","sa":"السعودية","qa":"قطر","ae":"الإمارات","kw":"الكويت","bh":"البحرين","om":"عُمان","eg":"مصر","ma":"المغرب","dz":"الجزائر","tn":"تونس",
"iq":"العراق","jo":"الأردن","lb":"لبنان","gb":"بريطانيا","ie":"إيرلندا","fr":"فرنسا","es":"إسبانيا","de":"ألمانيا","at":"النمسا","ch":"سويسرا","it":"إيطاليا",
"pt":"البرتغال","nl":"هولندا","be":"بلجيكا","pl":"بولندا","tr":"تركيا","gr":"اليونان","cy":"قبرص","rs":"صربيا","hr":"كرواتيا","ba":"البوسنة","si":"سلوفينيا",
"mk":"مقدونيا الشمالية","al":"ألبانيا","ro":"رومانيا","bg":"بلغاريا","hu":"المجر","cz":"التشيك","sk":"سلوفاكيا","se":"السويد","no":"النرويج","dk":"الدنمارك",
"fi":"فنلندا","ru":"روسيا","ua":"أوكرانيا","us":"أمريكا","ca":"كندا","mx":"المكسيك","br":"البرازيل","cl":"تشيلي","co":"كولومبيا","pe":"بيرو","in":"الهند",
"pk":"باكستان","sg":"سنغافورة","au":"أستراليا","nz":"نيوزيلندا","za":"جنوب أفريقيا","my":"ماليزيا","id":"إندونيسيا"}
BR.update({"movistar laliga":["Movistar"],"dazn laliga":["DAZN"],"canal +sport":["Canal+"],"canal +":["Canal+"],"supersport 7":["SuperSport"],
  "setanta sports":["Setanta"],"espn+":["ESPN"],"espn deportes":["ESPN"],"s sport":["S Sport"],"s sport plus":["S Sport"],"sky mexico":["Sky"],"cyta":["Cytavision"],
  "magenta tv":["Magenta Sport"],"tsn canada":["TSN"],"novasport":["Nova Sport"]})
ENT.update({"disney+":"platform","disney+ uk":"platform","espn+":"platform","s sport plus":"platform","fancode":"platform","go3":"platform","cazé tv":"platform"})
lega={"url":"https://en.legaseriea.it/serie-a/broadcasters","title":"Broadcasters | Where to Watch the Serie A Enilive 2025/26 | legaseriea.it","publisher":"Lega Serie A","kind":"official","retrievedAt":"2026-11-24"}
# Lega Serie A's own broadcasters page (extracted by the owner 2026-11-24): 198 countries, 73 broadcaster records. The page title
# still says 2025/26 and the league does not mark the current season as verified — kept as the page states it, never as 2026/27 proof.
sea=json.load(open('/tmp/rights/inputs/seriea-official-broadcasters.json',encoding='utf-8'))
bmap={b["id"]:b for b in sea["broadcasters"]}
review={i["broadcaster_id"] for i in sea.get("issues",[])}
SITE_NOTE="كما ينشره موقع الرابطة؛ عنوان الصفحة يذكر 2025/26 — لا يثبت حقوق 2026/27 ولا قناة المباراة ولا الحصرية"
def site_terrs(tag):
    out=[]
    for c in sea["countries"]:
        hs=[]
        for bid in c["broadcaster_ids"]:
            b=bmap[bid]
            if tag not in b["competition_tags"]: continue
            h=holder(b["name"],["unspecified"]); h["note"]=SITE_NOTE+f" · سجل الناقل في الموقع حُدّث {b['record_updated_at'][:10]} (ليس مدة عقد)"
            if bid in review: h.pop("brands",None); h.pop("brandsFrom",None); h["note"]="الاسم «"+b["name"]+"» كما نشره المصدر — يحتاج مراجعة، لا يُطابق بقنوات"
            hs.append(h)
        if not hs: continue
        srcc=dict(lega); srcc["url"]=sea["source_url"]
        t=terr(c["country_en"],hs,None,source=srcc,note=SITE_NOTE)
        t["countries"]=[ISO.get(c["country_code"].lower(), c["country_ar"])]; t["code"]=c["country_code"]; t["season"]="2025/26 (عنوان صفحة الرابطة)"
        out.append(t)
    return out
sa+=site_terrs("serie-a")
file('serie-a-2026-27','Serie A',["serie a","italian serie a","الدوري الإيطالي","الدوري الايطالي"],SA_EXC,"2026/27",lega,sa)
ci=[*[terr(c,[dz("حصري، كل المباريات")],"Europe",source=dazn_uk,contract="حتى نهاية 2028/29") for c in ["France","Germany","Austria","Switzerland"]],CYP(),
    *site_terrs("coppa-italia")]
file('coppa-italia-2026-27','Coppa Italia',["coppa italia","كأس إيطاليا"],["primavera","femminile","women","serie c","supercoppa"],"2026/27",lega,ci)
file('supercoppa-italiana-2026-27','Supercoppa Italiana',["supercoppa italiana","supercoppa","السوبر الإيطالي"],["primavera","femminile","women"],"2026/27",lega,
     [*[terr(c,[dz("حصري")],"Europe",source=dazn_uk,contract="حتى نهاية 2028/29") for c in ["France","Germany","Austria","Switzerland"]],CYP()])
# ---- LaLiga: LaLiga's own «where to watch» page per country (extracted by the owner 2026-11-24, 215 countries), plus the
# beIN MENA announcement (contract) and Cyta. The site's list proves neither the match channel nor exclusivity nor the contract.
site=json.load(open('/tmp/rights/inputs/laliga-broadcasters-2026-27.json',encoding='utf-8'))
lall=[]
ll={"url":"https://www.laliga.com/en-GB/news/bein-extends-exclusive-laliga-broadcast-rights-across-34-markets-in-mena-and-apac","title":"beIN Extends Exclusive LALIGA Broadcast Rights Across 34 Markets in MENA and APAC (laliga.com)","publisher":"LALIGA","kind":"official","retrievedAt":"2026-11-24"}
bein=holder("beIN SPORTS",["live"]); bein["entity"]="channel"; bein["note"]="حصري، كل المباريات الـ380 (إعلان LaLiga)"
lall.append(terr("MENA",[bein],"Africa and Middle East",source=ll,contract="حتى نهاية 2027/28"))
lall.append(CYP(r4k=True))     # the holder's own page first: it says «selected matches» and 4K
for c in site["countries"]:
    code=c["code"].lower()
    srcc={"url":c["source_url"],"title":f"LALIGA — where to watch ({c['country_en']})","publisher":"LALIGA","kind":"official","retrievedAt":site["retrieved_at_utc"][:10]}
    hs=[]
    for n in c["broadcasters"]:
        h=holder(n,["unspecified"]); h["note"]="كما يعرضه موقع LaLiga — لا يثبت قناة المباراة ولا الحصرية ولا مدة العقد"; hs.append(h)
    t=terr(c["country_en"],hs,None,source=srcc) if hs else terr(c["country_en"],[],None,status="unverified",source=srcc,
        note="الموقع لم يعرض ناقلًا لهذه الدولة (أو لم تُقرأ صفحتها) — بيانات ناقصة")
    t["countries"]=[ISO.get(code, c["country_ar"])]
    t["code"]=c["code"]
    lall.append(t)
for i in [i for i in site.get("issues",[]) if i["country"] not in {c["code"] for c in site["countries"]}]:
    lall.append(terr(i["country"],[],None,status="unverified",note="صفحة الدولة لم تُقرأ ("+i["issue"]+") — بيانات ناقصة"))
file('laliga-2026-27','LaLiga',["laliga","la liga","laliga ea sports","primera division","الدوري الإسباني","الدوري الاسباني"],
     ["hypermotion","segunda","2","liga f","women","womens","femenina","futsal","smartbank"],"2026/27",
     {"url":site["source"],"title":"LALIGA — where to watch LALIGA EA SPORTS, per country (extracted 2026-11-24, 215 of 216 countries)","publisher":"LALIGA","kind":"official","retrievedAt":"2026-11-24"},lall)
# ---- Cyta-only competitions
for slug,comp,keys,exc,r4k in [("fa-cup-2026-27","FA Cup",["fa cup","emirates fa cup","كأس الاتحاد الإنجليزي"],["women","womens","youth","trophy","vase"],False),
    ("efl-cup-2026-27","EFL Cup",["efl cup","carabao cup","كأس الرابطة الإنجليزية"],["women","scottish"],False),
    ("copa-del-rey-2026-27","Copa del Rey",["copa del rey","كأس ملك إسبانيا"],["women","basket","reina"],False),
    ("ligue-1-2026-27","Ligue 1",["ligue 1","الدوري الفرنسي"],["algeria","algerian","tunisia","ivory","cote","senegal","cameroon","benin","women","feminine"],False),
    ("eredivisie-2026-27","Eredivisie",["eredivisie","الدوري الهولندي"],["vrouwen","women"],False),
    ("liga-portugal-2026-27","Liga Portugal",["liga portugal","primeira liga","الدوري البرتغالي"],["2","women","feminina"],False)]:
    file(slug,comp,keys,exc,"2026/27",cy,[CYP(r4k)])
nova=holder("Novasports",["live","selected"]); nova["note"]="ضمن باقة Variety Pack على Cytavision حسب صفحة Cyta؛ مباريات مختارة"
file('bundesliga-2026-27','Bundesliga',["bundesliga","الدوري الألماني"],["2","austria","austrian","frauen","women"],"2026/27",cy,
     [terr("Cyprus",[nova],"Europe",source=cy,note="الصفحة لا تذكر الموسم؛ كما هي في 2026-11-24")])
