import json,re,sys
# territory → our country labels (MatchGuideCore.country / countryNames) — only where the territory is one country or a stated region
T={"Albania":["ألبانيا"],"Austria":["النمسا"],"Belgium":["بلجيكا"],"Bosnia and Herzegovina":["البوسنة"],"Bulgaria":["بلغاريا"],"Croatia":["كرواتيا"],
"Cyprus":["قبرص"],"Czechia":["التشيك"],"Denmark":["الدنمارك"],"Finland":["فنلندا"],"France":["فرنسا"],"Germany":["ألمانيا"],"Greece":["اليونان"],
"Hungary":["المجر"],"Italy":["إيطاليا"],"Netherlands":["هولندا"],"North Macedonia":["مقدونيا الشمالية"],"Norway":["النرويج"],"Poland":["بولندا"],
"Portugal":["البرتغال"],"Republic of Ireland":["إيرلندا"],"Romania":["رومانيا"],"Russia":["روسيا"],"Serbia":["صربيا"],"Slovakia":["سلوفاكيا"],
"Slovenia":["سلوفينيا"],"Spain":["إسبانيا"],"Sweden":["السويد"],"Switzerland":["سويسرا"],"Türkiye":["تركيا"],"Ukraine":["أوكرانيا"],
"United Kingdom":["بريطانيا"],"Canada":["كندا"],"Mexico":["المكسيك"],"Brazil":["البرازيل"],"Argentina":["الأرجنتين"],"United States of America":["أمريكا"],
"Australia":["أستراليا"],"New Zealand":["نيوزيلندا"],"South Africa":["جنوب أفريقيا"],"Malaysia":["ماليزيا"],"Indonesia":["إندونيسيا"],"Singapore":["سنغافورة"],
"Pakistan":["باكستان"],"Middle East/North Africa":["عربي"],"MENA":["عربي"]}
# country codes as schedules write them (LiveSoccerTV uses names, beIN feed QA) — for matching a schedule's country to a territory
CODES={"Netherlands":["nl","netherlands"],"France":["fr","france"],"United Kingdom":["gb","uk","united kingdom","england"],"Spain":["es","spain"],
"Italy":["it","italy"],"Germany":["de","germany"],"Portugal":["pt","portugal"],"Türkiye":["tr","turkey","türkiye"],"Belgium":["be","belgium"],
"United States of America":["us","usa","united states"],"Canada":["ca","canada"],"Republic of Ireland":["ie","ireland"],"Poland":["pl","poland"],
"Austria":["at","austria"],"Switzerland":["ch","switzerland"],"Greece":["gr","greece"],"Mexico":["mx","mexico"],"Brazil":["br","brazil"],
"Australia":["au","australia"],"Middle East/North Africa":["mena","qa","qatar","sa","saudi arabia","ae","united arab emirates","bh","bahrain","kw","kuwait","om","oman","eg","egypt","jo","jordan","lb","lebanon","iq","iraq","ma","morocco","dz","algeria","tn","tunisia","ly","libya"],
"MENA":["mena","qa","qatar","sa","saudi arabia","ae","united arab emirates","bh","bahrain","kw","kuwait","om","oman","eg","egypt","jo","jordan","lb","lebanon","iq","iraq","ma","morocco","dz","algeria","tn","tunisia","ly","libya"]}
def build(src, comp, keys, out):
    lines=open(src,encoding='utf-8').read().splitlines()
    meta={l.split(':',1)[0]:l.split(':',1)[1].strip() for l in lines[:5] if ':' in l}
    region=None; terr=[]
    for l in lines[5:]:
        if l.startswith('###'): region=l.strip('# ').strip(); continue
        if ':' not in l or not l.strip(): continue
        t,h=l.split(':',1)
        holders=[]
        for x in re.split(r',(?![^(]*\))',h):
            x=x.strip()
            if not x: continue
            hl=x.endswith('*'); holders.append({"name":x.rstrip('*').strip(),"highlightsOnly":hl,"channels":[]})
        t=t.strip()
        terr.append({"territory":t,"region":region,"countries":T.get(t,[]),"codes":CODES.get(t,[]),"holders":holders})
    season=meta['SEASON']; y=int(season[:4])
    d={"format":"shasha-rights","version":1,
       "competition":{"name":comp,"keys":keys,"excludes":["women","womens","youth","u19","u-19","futsal","سيدات","للشباب"]},
       "season":season,"validFrom":f"{y}-07-01","validTo":f"{y+1}-06-30",
       "validityNote":"مشتقة من اسم الموسم في الصفحة الرسمية (2026/27) — الصفحة لا تذكر تواريخ العقود",
       "source":{"url":meta['SOURCE'],"title":meta['TITLE'],"publisher":"UEFA","kind":"official","retrievedAt":meta['RETRIEVED'],"note":meta.get('NOTE','')},
       "territories":terr}
    json.dump(d,open(out,'w',encoding='utf-8'),ensure_ascii=False,indent=1)
    print(out,len(terr),sum(len(x['holders']) for x in terr))
build('/tmp/rights/ucl-2026-27.md','UEFA Champions League',["uefa champions league","champions league","دوري أبطال أوروبا","دوري ابطال اوروبا","ucl"],'/tmp/rights/out/uefa-champions-league-2026-27.json')
build('/tmp/rights/uel-2026-27.md','UEFA Europa League',["uefa europa league","europa league","الدوري الأوروبي","الدوري الاوروبي","uel"],'/tmp/rights/out/uefa-europa-league-2026-27.json')
